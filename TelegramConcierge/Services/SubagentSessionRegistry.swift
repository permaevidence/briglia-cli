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
    }

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
        let userMessage = Message(role: .user, content: initialPrompt, timestamp: Date())
        let session = Session(
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
        sessions[id] = session
        persist(session)
        pruneLRU()
        return (id, session)
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
            let assistantMsg = Message(role: .assistant, content: priorText, timestamp: Date())
            session.messages.append(assistantMsg)
            session.lastAssistantText = nil
        }

        let userMsg = Message(role: .user, content: continuationPrompt, timestamp: Date())
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
    func applyCompaction(sessionId: String, messages: [Message], toolInteractions: [ToolInteraction]) {
        guard var session = sessions[sessionId] else { return }
        session.messages = messages
        session.toolInteractions = toolInteractions
        session.lastUsed = Date()
        sessions[sessionId] = session
        persist(session)
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
        responsesMode: Bool = false
    ) -> Bool {
        guard var session = sessions[sessionId] else { return false }
        session.totalTurns += additionalTurns
        session.totalSpendUSD += additionalSpend
        session.lastUsed = Date()
        session.lastAssistantText = finalAssistantText
        session.toolInteractions.append(contentsOf: newToolInteractions)
        if responsesMode {
            // Completed native turns own their interactions in chronological
            // canonical Messages. The separate list is only this run's pending
            // checkpoint, so resume cannot move old calls behind a new user turn.
            var final = Message(role: .assistant,
                content: finalAssistantText ?? "[Subagent interrupted; inspect recorded tool outcomes before continuing.]",
                toolInteractions: session.toolInteractions)
            final.responsesReplay = responsesReplay
            session.messages.append(final)
            session.toolInteractions = []
            session.lastAssistantText = nil
        }


        // Merge new unique tool names preserving first-seen order.
        let existing = Set(session.toolsCalled)
        for name in newToolsCalled where !existing.contains(name) {
            session.toolsCalled.append(name)
        }

        sessions[sessionId] = session
        return persist(session)
    }

    // MARK: - Query

    func get(_ sessionId: String) -> Session? {
        sessions[sessionId]
    }

    /// Paginated listing sorted by `lastUsed` descending (most recent first).
    func list(limit: Int = 20, offset: Int = 0) -> (sessions: [Session], total: Int) {
        let sorted = sessions.values.sorted { $0.lastUsed > $1.lastUsed }
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

    /// Evict UNPINNED sessions with the oldest `lastUsed` timestamps until
    /// the unpinned pool is at or below `maxSessions`. Called after create()
    /// and after the initial disk hydration. Pinned (watcher-bound)
    /// sessions bypass the budget entirely — they are neither candidates
    /// nor counted, so 50 pinned lanes still leave the full 300-session
    /// pool for ordinary sessions.
    private func pruneLRU() {
        let unpinned = sessions.values.filter { !pinnedSessionIds.contains($0.id) }
        guard unpinned.count > Self.maxSessions else { return }
        let excess = unpinned.count - Self.maxSessions
        var evicted = 0
        for session in unpinned.sorted(by: { $0.lastUsed < $1.lastUsed }).prefix(excess) {
            sessions.removeValue(forKey: session.id)
            deletePersisted(session.id)
            evicted += 1
        }
        if evicted > 0 {
            print("[SubagentSessionRegistry] Evicted \(evicted) LRU session(s); retained \(sessions.count).")
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
