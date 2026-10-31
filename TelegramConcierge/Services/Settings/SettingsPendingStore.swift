import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// `configRoot/settings-pending.json` (KEYLESS_WEB_AND_LIVE_MENU plan B.5):
/// the staged changes (one slot per category, `ai` and `email`), the
/// attempt journal of every commit with a durable auth effect, every scope
/// transition and every pending apply, and the last 20 results. 0600,
/// private atomic write + fsync, serialized by `settings-pending.lock`.
/// Secret-bearing by design (D18): a staged change holds its complete
/// prepared change. Written only by the settings owner.
///
/// Lock order: … → `secrets.lock` → `settings-pending.lock`. A section of
/// this store never writes the secret store.
enum SettingsPendingStore {
    static let fileName = "settings-pending.json"
    static var url: URL { StoragePaths.configRoot.appendingPathComponent(fileName) }
    static var lockURL: URL { StoragePaths.configRoot.appendingPathComponent("settings-pending.lock") }
    static let maxResults = 20

    struct Staged: Codable {
        var ticket: String
        var change: PreparedChange
        var stagedAt: Date
    }

    struct Active: Codable {
        var ticket: String
        var attempt: String
        var change: PreparedChange
        /// "claimed" (no durable effect yet) or "persisted" (after 8.4).
        var state: String
        var claimedAt: Date
    }

    struct Slot: Codable {
        var staged: Staged?
        var active: Active?
        var isEmpty: Bool { staged == nil && active == nil }
    }

    /// What a ChatGPT auth store looked like (old) or will look like
    /// (projected) for one attempt (plan B.4a 8.1).
    struct AuthEvidence: Codable, Equatable {
        var absent: Bool
        var generation: String?
        var pending: String?
        var pendingOwner: String?
        var hasCredential: Bool

        init(_ state: SubscriptionAuthState?) {
            absent = state == nil
            generation = state?.generation
            pending = state?.pendingLogin
            pendingOwner = state?.pendingLoginBy
            hasCredential = state?.credential != nil
        }

        func matches(_ state: SubscriptionAuthState?) -> Bool { self == AuthEvidence(state) }
    }

    struct Attempt: Codable {
        var attempt: String
        /// "commit", "pending-apply" or "scope".
        var operation: String
        var category: String
        var ticket: String?
        var clientRequestId: String
        var label: String
        /// An auth-store mutation is part of this attempt.
        var authEffect: Bool
        var authKind: String?
        var storePath: String?
        var oldEvidence: AuthEvidence?
        var projectedEvidence: AuthEvidence?
        var secretsKeys: [String]
        /// "intent", then "secrets-done" — scope: "retire-failed-before-replace",
        /// "retired-unconfirmed", "own-retired", "done".
        var steps: [String]
        /// Scope transitions: "own->shared" / "shared->own"; "own" / "none".
        var direction: String?
        var retirement: String?
        var startedAt: Date
    }

    struct Result: Codable, Equatable {
        var ticket: String?
        var clientRequestId: String?
        var category: String
        var label: String
        /// applied | persisted | dropped | failed | partial | uncertain | cancelled
        var state: String
        var message: String?
        var at: Date
    }

    struct Document: Codable {
        var version = 1
        var slots: [String: Slot] = [:]
        var attempts: [String: Attempt] = [:]
        var lastResults: [Result] = []

        var isEmpty: Bool { slots.values.allSatisfy(\.isEmpty) && attempts.isEmpty && lastResults.isEmpty }

        mutating func appendResult(_ r: Result) {
            lastResults.append(r)
            if lastResults.count > SettingsPendingStore.maxResults {
                lastResults.removeFirst(lastResults.count - SettingsPendingStore.maxResults)
            }
        }

        var stagedCategories: [String] { slots.filter { $0.value.staged != nil }.map(\.key).sorted() }
    }

    struct Damaged: Error, CustomStringConvertible { let description: String }

    private static let processLock = NSLock()
    /// Selftest seam: fail the next writes (nothing reaches disk).
    nonisolated(unsafe) static var failWritesForTesting = false
    /// Selftest seam: runs after each successful write with the new document.
    nonisolated(unsafe) static var afterWriteForTesting: ((Document) -> Void)?

    /// Strict read: absent → empty; unreadable or malformed → throws.
    static func read() throws -> Document {
        processLock.lock(); defer { processLock.unlock() }
        return try readUnlocked()
    }

    private static func readUnlocked() throws -> Document {
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            if !FileManager.default.fileExists(atPath: url.path) { return Document() }
            throw Damaged(description: "\(url.path) cannot be read: \(error.localizedDescription)")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let doc = try? decoder.decode(Document.self, from: data), doc.version == 1 else {
            throw Damaged(description: "\(url.path) is damaged; move it aside to drop the waiting settings changes")
        }
        return doc
    }

    /// Read-modify-write under the in-process lock and the cross-process
    /// flock. An unchanged document is not written; an empty one is removed.
    @discardableResult
    static func update<T>(_ body: (inout Document) throws -> T) throws -> T {
        processLock.lock(); defer { processLock.unlock() }
        try PrivateStorage.ensureDirectory(StoragePaths.configRoot)
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Damaged(description: "cannot open \(lockURL.path)") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw Damaged(description: "cannot lock \(lockURL.path)") }
        var doc = try readUnlocked()
        let before = try encode(doc)
        let value = try body(&doc)
        let after = try encode(doc)
        if after != before { try write(doc, data: after) }
        return value
    }

    private static func encode(_ doc: Document) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(doc)
    }

    private static func write(_ doc: Document, data: Data) throws {
        if failWritesForTesting { throw Damaged(description: "injected settings-pending write failure") }
        if doc.isEmpty {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
                try? PrivateStorage.fsyncDirectory(StoragePaths.configRoot.path)
            }
        } else {
            try PrivateStorage.writeAtomically(data, to: url, mode: 0o600)
        }
        afterWriteForTesting?(doc)
    }

    /// Wait for and briefly hold the lock (the upgrade barrier's exit path,
    /// plan B.10): no write of this store is cut in half.
    static func holdLockForExit() -> Int32 {
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        if fd >= 0 { _ = flock(fd, LOCK_EX) }
        return fd
    }

    /// `/deleteuserdata` deletes the file; Mind import discards it.
    static func remove() throws {
        processLock.lock(); defer { processLock.unlock() }
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        defer { if fd >= 0 { close(fd) } }
        if fd >= 0 { _ = flock(fd, LOCK_EX) }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
            try? PrivateStorage.fsyncDirectory(StoragePaths.configRoot.path)
        }
    }
}
