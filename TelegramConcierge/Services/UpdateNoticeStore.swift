import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Files of the update-available notice (security plan v8 §5.6):
/// - setting `~/.config/briglia/update-check.json` (survives
///   `/deleteuserdata`; unreadable → OFF with attention);
/// - derived state `~/.local/share/briglia/update/notice.json` (corrupt or
///   above 2 MiB → quarantined, fresh state);
/// - one `flock` on `~/.config/briglia/update-check.lock`, OUTSIDE the data
///   subtree `/deleteuserdata` removes, never held across a network call,
///   a send or an exec.
/// Every read-modify-write goes through `transaction`: lock, re-read,
/// mutate, write atomically (write, fsync, rename, parent fsync).
enum UpdateNoticeStore {
    struct StoreError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Paths {
        var setting: URL
        var lock: URL
        var state: URL

        static var live: Paths {
            // Machine-level (MULTI_ASSISTANT_PLAN §5.5): the stores live in
            // default's roots for every profile; only default sends notices,
            // extras read them.
            Paths(setting: MachinePaths.defaultConfigRoot().appendingPathComponent("update-check.json"),
                  lock: MachinePaths.defaultConfigRoot().appendingPathComponent("update-check.lock"),
                  state: MachinePaths.defaultDataRoot().appendingPathComponent("update/notice.json"))
        }
    }

    enum SettingRead: Equatable {
        case value(UpdateCheckSetting)
        /// No file yet: the default (ON, N3).
        case defaultOn
        /// Present but unreadable → treated as OFF (no requests).
        case unreadable
        var enabled: Bool {
            switch self {
            case .value(let s): return s.enabled
            case .defaultOn: return true
            case .unreadable: return false
            }
        }
        var generation: UInt64 {
            if case .value(let s) = self { return s.generation }
            return 0
        }
    }

    struct Snapshot {
        var setting: SettingRead
        var state: UpdateNoticeState
        /// The state file was unreadable/oversized and was moved aside now.
        var quarantined: Bool
    }

    // MARK: - Coding

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }

    static func encodeState(_ s: UpdateNoticeState) throws -> Data {
        let data = try encoder().encode(s)
        guard data.count <= UpdateNotice.maxStateBytes else {
            throw StoreError(message: "update state would be \(data.count) bytes (limit \(UpdateNotice.maxStateBytes)) — refusing to write")
        }
        return data
    }

    // MARK: - Lock

    /// Runs `body` holding the exclusive lock. The lock file's inode is
    /// stable (never deleted by any path).
    static func withLock<T>(_ paths: Paths, _ body: () throws -> T) throws -> T {
        try PrivateStorage.ensureDirectoryScoped(paths.lock.deletingLastPathComponent())
        let fd = open(paths.lock.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw StoreError(message: "cannot open \(paths.lock.path): \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else {
            throw StoreError(message: "cannot lock \(paths.lock.path): \(String(cString: strerror(errno)))")
        }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }

    // MARK: - Reads (caller holds the lock, or accepts a lockless read)

    static func readSetting(_ paths: Paths) -> SettingRead {
        var st = stat()
        if lstat(paths.setting.path, &st) != 0 && errno == ENOENT { return .defaultOn }
        guard let data = FileManager.default.contents(atPath: paths.setting.path),
              let s = try? decoder().decode(UpdateCheckSetting.self, from: data), s.schema == 1 else { return .unreadable }
        return .value(s)
    }

    /// (state, quarantined): a file that cannot be decoded, has another
    /// schema, or exceeds the byte cap is renamed aside and replaced by a
    /// fresh state (first-observation residual, §5.2).
    static func readState(_ paths: Paths, now: Date) -> (UpdateNoticeState, Bool) {
        var st = stat()
        if lstat(paths.state.path, &st) != 0 && errno == ENOENT { return (UpdateNoticeState(), false) }
        let size = Int(st.st_size)
        if size <= UpdateNotice.maxStateBytes,
           (st.st_mode & S_IFMT) == S_IFREG,
           let data = FileManager.default.contents(atPath: paths.state.path),
           let s = try? decoder().decode(UpdateNoticeState.self, from: data), s.schema == 1 {
            return (s, false)
        }
        let aside = paths.state.deletingLastPathComponent()
            .appendingPathComponent("notice.json.corrupt-\(Int(now.timeIntervalSince1970))")
        _ = rename(paths.state.path, aside.path)
        return (UpdateNoticeState(), true)
    }

    // MARK: - Transactions

    /// Lock → re-read setting and state → `body` (returns whether it changed
    /// anything) → atomic write of a changed state. A write failure throws:
    /// the caller sends nothing from that derivation (§5.5 step 3).
    @discardableResult
    static func transaction<T>(_ paths: Paths, now: Date,
                               _ body: (SettingRead, inout UpdateNoticeState) throws -> (changed: Bool, result: T)) throws -> T {
        try withLock(paths) {
            let setting = readSetting(paths)
            var (state, quarantined) = readState(paths, now: now)
            let before = state
            let (changed, result) = try body(setting, &state)
            if quarantined || (changed && state != before) {
                try writeState(paths, state)
            }
            return result
        }
    }

    /// Selftest seam: every state write fails (unwritable storage).
    nonisolated(unsafe) static var failWritesForTesting = false

    static func writeState(_ paths: Paths, _ state: UpdateNoticeState) throws {
        if failWritesForTesting { throw StoreError(message: "injected write failure") }
        let data = try encodeState(state)
        try PrivateStorage.ensureDirectoryScoped(paths.state.deletingLastPathComponent())
        try PrivateStorage.writeAtomically(data, to: paths.state)
    }

    /// `/upgradecheck on|off` (any process): serialized with the checker,
    /// so a late check result can never overwrite an explicit OFF.
    static func setEnabled(_ enabled: Bool, paths: Paths, now: Date) throws {
        try withLock(paths) {
            var setting: UpdateCheckSetting
            switch readSetting(paths) {
            case .value(let s): setting = s
            case .defaultOn, .unreadable: setting = UpdateCheckSetting(enabled: true)
            }
            setting.enabled = enabled
            setting.changedAt = now
            try PrivateStorage.writeAtomically(try encoder().encode(setting), to: paths.setting)
        }
    }

    /// `/deleteuserdata` (§5.6): under the lock, bump the notice generation
    /// (kept in the setting file, which the deletion keeps) so a check or
    /// send in progress cannot write back, then delete the derived state.
    /// An explicit OFF survives.
    static func wipeDerivedState(paths: Paths, now: Date) throws {
        try withLock(paths) {
            var setting: UpdateCheckSetting
            switch readSetting(paths) {
            case .value(let s): setting = s
            case .defaultOn: setting = UpdateCheckSetting(enabled: true)
            case .unreadable: setting = UpdateCheckSetting(enabled: false)
            }
            setting.generation &+= 1
            try PrivateStorage.writeAtomically(try encoder().encode(setting), to: paths.setting)
            if unlink(paths.state.path) != 0 && errno != ENOENT {
                throw StoreError(message: "could not delete \(paths.state.path): \(String(cString: strerror(errno)))")
            }
            // §9.5.5: the local-tools table and the advisory-list
            // observation go with it, under the same lock and generation.
            try LocalAdvisoryStore.unlinkDerived(.under(paths))
        }
    }

    /// Lockless snapshot for doctor, the menu and /status (they only read).
    static func snapshot(_ paths: Paths = .live) -> (SettingRead, UpdateNoticeState?) {
        let setting = readSetting(paths)
        var st = stat()
        guard lstat(paths.state.path, &st) == 0, Int(st.st_size) <= UpdateNotice.maxStateBytes,
              let data = FileManager.default.contents(atPath: paths.state.path),
              let s = try? decoder().decode(UpdateNoticeState.self, from: data) else { return (setting, nil) }
        return (setting, s)
    }
}
