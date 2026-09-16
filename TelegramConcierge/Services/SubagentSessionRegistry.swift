import Foundation

/// Persistent registry of subagent sessions, backed by disk.
///
/// Each session captures the full conversation state of a subagent so the
/// main agent can resume it at any time by passing `session_id` to the
/// Agent tool.
///
/// Conversation state (messages, tool interactions, totals) is serialized
/// to `~/.local/share/briglia/subagent_sessions/<id>.json` on every mutation and
/// reloaded at app start. Subprocess-backed resources (e.g. Playwright
/// browser) still have to relaunch after an app restart — only the message
/// history is restored, not live OS state.
///
/// Sessions are resumed whole: context growth is bounded by SubagentRunner's
/// mid-run compaction (summarize oldest, keep newest verbatim), not by any
/// trimming here.
///
/// LRU retention: up to `maxSessions` (default 300) are kept on disk. When
/// the cap is exceeded, sessions with the oldest `lastUsed` timestamp are
/// evicted first. A frequently-resumed session keeps its `lastUsed` current
/// and is never evicted before newer-but-idle sessions — age is measured by
/// "last touch," not by creation date.
///
/// Session IDs are 5-char base36 strings (~60M possible values) — short
/// enough for an LLM to track in conversation context.
actor SubagentSessionRegistry {

    static let shared = SubagentSessionRegistry()

    struct Session: Codable {
        let id: String
        let subagentType: String
        let description: String
        let created: Date
        var lastUsed: Date
        var totalTurns: Int
        var totalSpendUSD: Double
        var toolsCalled: [String]      // unique, ordered by first appearance

        // Conversation state — enough for SubagentRunner to resume.
        var messages: [Message]                 // user messages fed to the LLM
        var toolInteractions: [ToolInteraction] // accumulated tool call/result pairs
        var lastAssistantText: String?          // final text from last run (becomes assistant message on resume)
        /// When `lastAssistantText` was produced (recorded at commit), so the
        /// message materialized at resume keeps the reply's ORIGINAL time
        /// instead of being dated at the resume. Additive optional field: a
        /// legacy session without it falls back to `lastUsed`, which commit
        /// set at that same event — never the reload time.
        var lastAssistantAt: Date? = nil
        /// First 80 characters of the first task prompt, whitespace-collapsed
        /// and marker-neutralized (WEB_SUBAGENT_PLAN §4.7). Optional decode
        /// keeps every existing file valid.
        var topic: String? = nil
        /// Web researcher sessions only (§4.2, §4.5): the evidence ledger
        /// (one record per retrieval result) and the queries run, persisted
        /// with the session and restored at resume.
        var webEvidence: [WebEvidenceRecord]? = nil
        var webQueriesUsed: [String]? = nil
        /// Number of report files written for this session (`report_path`
        /// numbering, §4.3 O6).
        var webReportCount: Int? = nil

        /// Pool membership (§4.7): Web researcher sessions live in their own
        /// pool with its own cap and expiry.
        var kind: Kind { subagentType == SubagentTypes.webResearcherName ? .web : .general }
    }

    enum Kind { case general, web }

    private var sessions: [String: Session] = [:]

    /// Sessions bound to live watchers (triage lanes) — they BYPASS the LRU
    /// budget entirely: the `maxSessions` cap applies to the unpinned pool
    /// only, so pinning never squeezes ordinary sessions out. Pushed by
    /// ReminderService whenever watcher rows change, and hydrated directly
    /// from reminders.json at init so the initial prune can never evict a
    /// pinned session before the first push arrives. Pinned lanes have
    /// their own cap (`ReminderService.maxTriageLanes`) enforced at watcher
    /// creation.
    private var pinnedSessionIds: Set<String> = []

    private init() {
        pinnedSessionIds = Self.hydratePinnedFromReminders()
        loadAllFromDisk()
    }

    /// Read the pinned set straight from the reminder store (read-only) —
    /// the registry initializes before ReminderService can push, and the
    /// hydration prune must already know which sessions are protected.
    private static func hydratePinnedFromReminders() -> Set<String> {
        let url = StoragePaths.dataRoot.appendingPathComponent("reminders.json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let reminders = try? decoder.decode([Reminder].self, from: data) else { return [] }
        return Set(reminders.compactMap { $0.triggered ? nil : $0.triageSessionId })
    }

    /// Replace the pinned set (watcher-bound triage sessions). Re-runs the
    /// LRU prune: sessions that just UNpinned (last watcher left) re-enter
    /// the normal pool and become evictable in lastUsed order.
    func setPinnedSessionIds(_ ids: Set<String>) {
        pinnedSessionIds = ids
        pruneLRU()
    }

    // MARK: - Create / Resume

    /// Create a fresh session and return its ID.
    func create(subagentType: String, description: String, initialPrompt: String) -> (id: String, session: Session) {
        let id = generateId()
        let userMessage = Message(role: .user, content: initialPrompt, timestamp: HarnessClock.now())
        var session = Session(
            id: id,
            subagentType: subagentType,
            description: description,
            created: Date(),
            lastUsed: Date(),
            totalTurns: 0,
            totalSpendUSD: 0,
            toolsCalled: [],
            messages: [userMessage],
            toolInteractions: [],
            lastAssistantText: nil
        )
        session.topic = Self.topic(from: initialPrompt)
        sessions[id] = session
        persist(session)
        if session.kind == .web { sweepExpiredWebSessions() }
        pruneLRU()
        return (id, session)
    }

    /// Topic line of a session (§4.7): first 80 characters of the first task
    /// prompt, whitespace collapsed, marker-neutralized.
    static func topic(from prompt: String) -> String {
        let collapsed = prompt.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return MarkerNeutralizer.escape(String(collapsed.prefix(80)))
    }

    /// Prepare a session for resumption by appending a new user message.
    /// Returns the updated session (with the new message + prior assistant
    /// text converted to a message), or nil if the session_id is unknown.
    ///
    /// The session is resumed exactly where it left off — no trimming.
    /// Context size is bounded by SubagentRunner's mid-run compaction,
    /// which summarizes the oldest history whenever a run approaches the
    /// turn token budget (and eagerly at resume if a session is oversized).
    func prepareResume(sessionId: String, continuationPrompt: String) -> Session? {
        guard var session = sessions[sessionId] else { return nil }

        // If the prior run ended with a text response, inject it as an
        // assistant message so the subagent sees its own prior reply.
        if let priorText = session.lastAssistantText {
            // Original completion time of that reply (WEB_SUBAGENT_PLAN §12.2.5):
            // yesterday's reply is not dated today.
            let assistantMsg = Message(role: .assistant, content: priorText,
                                       timestamp: session.lastAssistantAt ?? session.lastUsed)
            session.messages.append(assistantMsg)
            session.lastAssistantText = nil
            session.lastAssistantAt = nil
        }

        let userMsg = Message(role: .user, content: continuationPrompt, timestamp: HarnessClock.now())
        session.messages.append(userMsg)
        session.lastUsed = Date()

        sessions[sessionId] = session
        persist(session)
        return session
    }

    /// Replace a session's conversation state with its compacted form.
    /// Called by SubagentRunner after mid-run compaction: the summary is
    /// already the first message and the evicted items are gone. The
    /// summary is only persisted here AFTER it was generated successfully,
    /// so a failed summarization never loses history from disk.
    func applyCompaction(sessionId: String, messages: [Message], toolInteractions: [ToolInteraction],
                         webEvidence: [WebEvidenceRecord]? = nil) {
        guard var session = sessions[sessionId] else { return }
        session.messages = messages
        session.toolInteractions = toolInteractions
        if let webEvidence { session.webEvidence = webEvidence }
        session.lastUsed = Date()
        sessions[sessionId] = session
        persist(session)
    }

    /// Persist the Web researcher's ledger and query log mid-run (after each
    /// tool batch), so a cancelled or crashed run keeps what it retrieved.
    func updateWebEvidence(sessionId: String, evidence: [WebEvidenceRecord], queries: [String]) {
        guard var session = sessions[sessionId] else { return }
        session.webEvidence = evidence
        session.webQueriesUsed = queries
        sessions[sessionId] = session
        persist(session)
    }

    /// Reserve the next report number of a Web session (§4.3 O6).
    func nextReportNumber(sessionId: String) -> Int {
        guard var session = sessions[sessionId] else { return 1 }
        let next = (session.webReportCount ?? 0) + 1
        session.webReportCount = next
        sessions[sessionId] = session
        persist(session)
        return next
    }

    /// Persist the full canonical interaction list before dispatch/continuation.
    /// The intent has explicit uncertain results so crash recovery never reruns it.
    func checkpointResponses(sessionId: String, interactions: [ToolInteraction]) -> Bool {
        guard var session = sessions[sessionId] else { return false }
        session.toolInteractions = interactions
        guard persist(session) else { return false }
        sessions[sessionId] = session
        return true
    }

    /// Update session after a run completes. Returns whether the session —
    /// including the run's final assistant text (the triage verdict record)
    /// — actually reached disk: SKIP acknowledgments are built on this
    /// persist, so its failure must surface to the dispatcher rather than
    /// being logged and swallowed (§3b integration prerequisite).
    @discardableResult
    func commitRun(
        sessionId: String,
        additionalTurns: Int,
        additionalSpend: Double,
        newToolsCalled: [String],
        newToolInteractions: [ToolInteraction],
        finalAssistantText: String?,
        responsesReplay: ResponsesReplayEnvelope? = nil,
        responsesMode: Bool = false,
        webEvidence: [WebEvidenceRecord]? = nil,
        webQueriesUsed: [String]? = nil
    ) -> Bool {
        guard var session = sessions[sessionId] else { return false }
        if let webEvidence { session.webEvidence = webEvidence }
        if let webQueriesUsed { session.webQueriesUsed = webQueriesUsed }
        session.totalTurns += additionalTurns
        session.totalSpendUSD += additionalSpend
        session.lastUsed = Date()
        session.lastAssistantText = finalAssistantText
        // Recorded once, at the event it describes (the reply's completion).
        let completedAt = HarnessClock.now()
        session.lastAssistantAt = finalAssistantText == nil ? nil : completedAt
        session.toolInteractions.append(contentsOf: newToolInteractions)
        if responsesMode {
            // Completed native turns own their interactions in chronological
            // canonical Messages. The separate list is only this run's pending
            // checkpoint, so resume cannot move old calls behind a new user turn.
            var final = Message(role: .assistant,
                content: finalAssistantText ?? "[Subagent interrupted; inspect recorded tool outcomes before continuing.]",
                timestamp: completedAt,
                toolInteractions: session.toolInteractions)
            final.responsesReplay = responsesReplay
            session.messages.append(final)
            session.toolInteractions = []
            session.lastAssistantText = nil
            session.lastAssistantAt = nil
        }


        // Merge new unique tool names preserving first-seen order.
        let existing = Set(session.toolsCalled)
        for name in newToolsCalled where !existing.contains(name) {
            session.toolsCalled.append(name)
        }

        sessions[sessionId] = session
        let persisted = persist(session)
        if session.kind == .web { sweepExpiredWebSessions() }
        return persisted
    }

    // MARK: - Query

    func get(_ sessionId: String) -> Session? {
        sessions[sessionId]
    }

    /// Paginated listing sorted by `lastUsed` descending (most recent first).
    /// `kind` nil = every session (the legacy single-pool listing).
    func list(limit: Int = 20, offset: Int = 0, kind: Kind? = nil) -> (sessions: [Session], total: Int) {
        let sorted = sessions.values.filter { kind == nil || $0.kind == kind! }.sorted { $0.lastUsed > $1.lastUsed }
        let total = sorted.count
        let page = Array(sorted.dropFirst(offset).prefix(limit))
        return (page, total)
    }

    /// Total number of sessions.
    var count: Int { sessions.count }

    // MARK: - Cleanup (app shutdown only)

    func removeAll() {
        for id in sessions.keys {
            deletePersisted(id)
        }
        sessions.removeAll()
    }

    /// Reload sessions after a Mind restore replaces the backing directory.
    /// Pins are re-hydrated from the (already restored) reminder store FIRST
    /// — the restored backup may bind different sessions, and pruning with
    /// the pre-restore pinned set could evict a restored watcher-bound
    /// session before ReminderService pushes the fresh pins.
    func reloadFromDisk() {
        pinnedSessionIds = Self.hydratePinnedFromReminders()
        sessions.removeAll()
        loadAllFromDisk()
    }

    // MARK: - LRU retention

    /// Maximum number of sessions retained. When exceeded, least-recently-used
    /// sessions are evicted on disk and in memory. Measured by `lastUsed`, so
    /// frequently-resumed sessions survive even if they were created long ago.
    static let maxSessions = 300

    /// The Web researcher pool (WEB_SUBAGENT_PLAN §4.7, O3): its own cap and
    /// a 14-day expiry, so web sessions never crowd out or evict the
    /// general pool. Pinned (watcher-bound) sessions are never Web —
    /// asserted in `pruneLRU`, not assumed.
    static let maxWebSessions = 40
    static let webSessionTTL: TimeInterval = 14 * 24 * 60 * 60

    /// Evict UNPINNED sessions with the oldest `lastUsed` timestamps until
    /// each unpinned pool is at or below its cap (`maxSessions` for the
    /// general pool, `maxWebSessions` for the web pool). Called after
    /// create() and after the initial disk hydration. Pinned (watcher-bound)
    /// sessions bypass the budget entirely — they are neither candidates
    /// nor counted, so 50 pinned lanes still leave the full 300-session
    /// pool for ordinary sessions.
    private func pruneLRU() {
        for session in sessions.values where session.kind == .web && pinnedSessionIds.contains(session.id) {
            print("[SubagentSessionRegistry] WARNING: pinned session \(session.id) is a Web session; treating it as unpinned for the web pool.")
        }
        for kind in [Kind.general, Kind.web] {
            let cap = kind == .web ? Self.maxWebSessions : Self.maxSessions
            let unpinned = sessions.values.filter { $0.kind == kind && (kind == .web || !pinnedSessionIds.contains($0.id)) }
            guard unpinned.count > cap else { continue }
            let excess = unpinned.count - cap
            var evicted = 0
            for session in unpinned.sorted(by: { $0.lastUsed < $1.lastUsed }).prefix(excess) {
                sessions.removeValue(forKey: session.id)
                deletePersisted(session.id)
                evicted += 1
            }
            if evicted > 0 {
                print("[SubagentSessionRegistry] Evicted \(evicted) LRU \(kind == .web ? "web " : "")session(s); retained \(sessions.count).")
            }
        }
    }

    /// Delete Web sessions whose `lastUsed` is older than `webSessionTTL`
    /// (the answers live in the main conversation). Runs at hydration and
    /// after each Web create/commit.
    private func sweepExpiredWebSessions() {
        let cutoff = Date().addingTimeInterval(-Self.webSessionTTL)
        let expired = sessions.values.filter { $0.kind == .web && $0.lastUsed < cutoff }
        for session in expired {
            sessions.removeValue(forKey: session.id)
            deletePersisted(session.id)
        }
        if !expired.isEmpty {
            print("[SubagentSessionRegistry] Expired \(expired.count) web session(s) older than 14 days.")
        }
    }

    // MARK: - Disk persistence

    private static let persistenceDirName = "subagent_sessions"
    private static let persistenceExtension = "json"

    /// Canonical on-disk location: `~/.local/share/briglia/subagent_sessions/`.
    /// Creates the directory if it does not yet exist.
    private static func persistenceDirectory() -> URL {
        let url = StoragePaths.dataRoot
            .appendingPathComponent(Self.persistenceDirName, isDirectory: true)
        try? PrivateStorage.ensureDirectory(url)
        return url
    }

    private static func persistenceURL(for id: String) -> URL {
        persistenceDirectory().appendingPathComponent("\(id).\(Self.persistenceExtension)")
    }

    /// Atomic write. An I/O error is logged, never raised — the in-memory
    /// session remains authoritative and the next mutation re-attempts —
    /// but the Bool result surfaces success to callers whose durability
    /// contracts depend on the write (triage SKIP acks).
    @discardableResult
    private func persist(_ session: Session) -> Bool {
        let url = Self.persistenceURL(for: session.id)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(session)
            try PrivateStorage.writeAtomically(data, to: url)
            return true
        } catch {
            print("[SubagentSessionRegistry] Failed to persist session \(session.id): \(error)")
            return false
        }
    }

    private func deletePersisted(_ id: String) {
        try? FileManager.default.removeItem(at: Self.persistenceURL(for: id))
    }

    /// Called once from the actor's init. Reads every `<id>.json` file in the
    /// persistence directory and hydrates the in-memory map. Corrupt entries
    /// are logged and skipped — they do not block other sessions from loading.
    private func loadAllFromDisk() {
        let dir = Self.persistenceDirectory()
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var loaded = 0
        for url in contents where url.pathExtension == Self.persistenceExtension {
            do {
                let data = try Data(contentsOf: url)
                var session = try decoder.decode(Session.self, from: data)
                // Requalify pre-v0.1.28 bare-model reasoning provenance for
                // records matching the currently configured model (same
                // migration + attribution rule as the main conversation's
                // load — long-pinned watcher sessions carry old records).
                var migrated = false
                for index in session.messages.indices {
                    guard let bare = session.messages[index].finalReasoningModel,
                          !bare.contains("#"),
                          let qualified = OpenRouterService.requalifiedLegacyProvenance(bareModelId: bare)
                    else { continue }
                    session.messages[index].finalReasoningModel = qualified
                    migrated = true
                }
                sessions[session.id] = session
                if migrated { _ = persist(session) }
                loaded += 1
            } catch {
                print("[SubagentSessionRegistry] Skipped corrupt session file \(url.lastPathComponent): \(error)")
            }
        }
        if loaded > 0 {
            print("[SubagentSessionRegistry] Restored \(loaded) session(s) from disk.")
        }
        sweepExpiredWebSessions()
        pruneLRU()
    }

    // MARK: - ID generation

    private let base36 = Array("0123456789abcdefghijklmnopqrstuvwxyz")
    private func generateId() -> String {
        var id: String
        repeat {
            id = String((0..<5).map { _ in base36.randomElement()! })
        } while sessions[id] != nil
        return id
    }
}

// MARK: - Per-session run serialization

/// FIFO mutex per subagent session id: a fire-triggered triage run, a second
/// fire on a shared session, and a main-agent resume can race — resumed runs
/// on the same session execute one at a time, in arrival order (§4). Each
/// Agent invocation creates its own SubagentRunner instance, so actor
/// isolation alone does not serialize across runs; this shared actor does.
/// Fresh sessions need no lock (their id is unknown to anyone else until
/// create() returns).
actor SubagentSessionLocks {
    static let shared = SubagentSessionLocks()

    private var held: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func acquire(_ sessionId: String) async {
        if !held.contains(sessionId) {
            held.insert(sessionId)
            return
        }
        await withCheckedContinuation { continuation in
            waiters[sessionId, default: []].append(continuation)
        }
    }

    func release(_ sessionId: String) {
        if var queue = waiters[sessionId], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[sessionId] = queue.isEmpty ? nil : queue
            next.resume()   // lock hands off directly to the next waiter
        } else {
            held.remove(sessionId)
        }
    }
}
