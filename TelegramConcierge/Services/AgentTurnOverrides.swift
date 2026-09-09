import Foundation

/// Per-agent max-turn override.
///
/// Lets the user pin a specific maximum-turn limit for the main agent and
/// each subagent type (built-in or user-defined), overriding the value baked
/// into `SubagentType.defaultMaxTurns` or `ConversationManager`'s safety cap.
///
/// Resolution order:
///   1. Per-agent override from `~/.config/briglia/agent-turns.json` (this file).
///   2. Built-in default (SubagentType.defaultMaxTurns or main-agent constant).
///
/// Config format:
/// ```json
/// {
///   "main":            200,
///   "Browse":          150,
///   "general-purpose": 150
/// }
/// ```
enum AgentTurnOverrides {

    // MARK: - Constants

    /// Fallback for the main agent when no override is set on disk.
    ///
    /// This is a runaway backstop, not a budget. Spend caps are off unless the
    /// user sets one (`/spend`) and active-turn compaction keeps the context
    /// from running out, so this count is the only automatic stop for a turn
    /// that loops without progress while nobody is watching. 5000 rounds is
    /// more than a day of continuous tool use; legitimate long tasks should
    /// never reach it. Reaching it is graceful: the turn ends with a forced
    /// final answer and "continue" resumes it (owner decision 2026-09-09).
    static let mainAgentDefault: Int = 5000

    // MARK: - Cache

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedOverrides: [String: Int]?

    // MARK: - Public API

    /// Returns the override for `agent`, or nil if none set. Case-insensitive
    /// match so callers don't have to worry about built-in capitalization.
    static func override(forAgent agent: String) -> Int? {
        let map = loadIfNeeded()
        if let direct = map[agent] { return direct }
        let lower = agent.lowercased()
        if let loose = map.first(where: { $0.key.lowercased() == lower }) {
            return loose.value
        }
        return nil
    }

    /// Snapshot of the full override map. Used by the Settings UI.
    static func currentOverrides() -> [String: Int] {
        loadIfNeeded()
    }

    /// Overwrite the full map on disk. Settings UI calls this after each edit.
    static func save(_ overrides: [String: Int]) throws {
        let url = overridesURL()
        try PrivateStorage.ensureDirectory(url.deletingLastPathComponent())

        var clean: [String: Int] = [:]
        for (agent, value) in overrides {
            guard value > 0 else { continue }
            clean[agent] = value
        }

        let data = try JSONSerialization.data(
            withJSONObject: clean,
            options: [.prettyPrinted, .sortedKeys]
        )
        try PrivateStorage.writeAtomically(data, to: url)

        cacheLock.lock()
        cachedOverrides = clean
        cacheLock.unlock()
    }

    /// Convenience: set (or clear with nil) a single agent's override.
    static func setOverride(_ value: Int?, forAgent agent: String) throws {
        var map = loadIfNeeded()
        if let v = value, v > 0 {
            map[agent] = v
        } else {
            map.removeValue(forKey: agent)
        }
        try save(map)
    }

    /// Force re-read of the JSON file on next access.
    static func reload() {
        cacheLock.lock()
        cachedOverrides = nil
        cacheLock.unlock()
    }

    // MARK: - Internal

    @discardableResult
    private static func loadIfNeeded() -> [String: Int] {
        cacheLock.lock()
        if let cached = cachedOverrides {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let loaded = loadFromDisk() ?? [:]
        cacheLock.lock()
        cachedOverrides = loaded
        cacheLock.unlock()
        return loaded
    }

    private static func loadFromDisk() -> [String: Int]? {
        let url = overridesURL()
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var out: [String: Int] = [:]
        for (agent, raw) in root {
            if let n = raw as? Int, n > 0 {
                out[agent] = n
            } else if let n = raw as? NSNumber {
                let v = n.intValue
                if v > 0 { out[agent] = v }
            }
        }
        return out
    }

    private static func overridesURL() -> URL {
        StoragePaths.configRoot
            .appendingPathComponent("agent-turns.json")
    }
}
