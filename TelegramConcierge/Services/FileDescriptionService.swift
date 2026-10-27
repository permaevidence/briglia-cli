import Foundation

/// Single storage authority for the cached file-description map — the ONLY
/// code that touches the underlying "FileDescriptions" preference. Both
/// FileDescriptionService (live cache, wipe's clearAll) and
/// MindExportService (export/import) go through it, so test isolation
/// covers every path that could read or DELETE the machine's real
/// descriptions (Codex, 2026-08-27: the wipe selftests reach clearAll if
/// the abort they test ever regresses).
enum FileDescriptionsStore {
    private static let storageKey = "FileDescriptions"

    /// Selftest seam: when set, reads/writes/clears go to this JSON file
    /// instead of the machine's UserDefaults. Preference domains ignore
    /// the XDG test roots, and a watchdog exit(3) or kill bypasses any
    /// defer-based restore — so tests must never touch the real store.
    /// Selftests set this BEFORE anything accesses descriptions.
    static var _testStoreURL: URL?

    static var isHermetic: Bool { _testStoreURL != nil }

    static func loadData() -> Data? {
        if let url = _testStoreURL { return try? Data(contentsOf: url) }
        return Prefs.store.data(forKey: storageKey)
    }

    static func storeData(_ data: Data) throws {
        if let url = _testStoreURL {
            try data.write(to: url, options: .atomic)
            return
        }
        Prefs.store.set(data, forKey: storageKey)
    }

    static func clear() {
        if let url = _testStoreURL {
            try? FileManager.default.removeItem(at: url)
            return
        }
        Prefs.store.removeObject(forKey: storageKey)
    }
}

/// Simple service to persist file descriptions for future reference.
/// All storage goes through FileDescriptionsStore.
actor FileDescriptionService {
    static let shared = FileDescriptionService()

    private var cache: [String: String] = [:]
    private var loaded = false

    private init() {}

    /// Load descriptions from storage
    private func loadIfNeeded() {
        guard !loaded else { return }
        if let data = FileDescriptionsStore.loadData(),
           let descriptions = try? JSONDecoder().decode([String: String].self, from: data) {
            cache = descriptions
        }
        loaded = true
    }

    /// Save descriptions to storage
    private func persist() {
        if let data = try? JSONEncoder().encode(cache) {
            try? FileDescriptionsStore.storeData(data)
        }
    }

    /// Save a description for a file
    func save(filename: String, description: String) {
        loadIfNeeded()
        cache[filename] = description
        persist()
        print("[FileDescriptionService] Saved description for \(filename): \(description.prefix(50))...")
    }

    /// Get description for a file
    func get(filename: String) -> String? {
        loadIfNeeded()
        return cache[filename]
    }

    /// Get all descriptions
    func getAll() -> [String: String] {
        loadIfNeeded()
        return cache
    }

    /// Save multiple descriptions at once
    func saveMultiple(_ descriptions: [String: String]) {
        loadIfNeeded()
        for (filename, description) in descriptions {
            cache[filename] = description
            print("[FileDescriptionService] Saved description for \(filename): \(description.prefix(50))...")
        }
        persist()
    }

    /// Clear all stored descriptions
    func clearAll() {
        cache.removeAll()
        FileDescriptionsStore.clear()
        print("[FileDescriptionService] Cleared all file descriptions")
    }

    /// Reload descriptions after a Mind restore replaces the stored data.
    func reloadFromStorage() {
        cache.removeAll()
        loaded = false
        loadIfNeeded()
    }
}
