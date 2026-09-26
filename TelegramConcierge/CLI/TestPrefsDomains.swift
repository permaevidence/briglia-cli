import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Throwaway UserDefaults domains created by the selftests are removed
/// COMPLETELY when a run finishes. `removePersistentDomain` alone empties
/// the domain, but cfprefsd (macOS) then writes a 42-byte empty plist shell
/// for it a few seconds later (measured: ~5.6 s after the removal, from a
/// timer — also after the removing process has exited), so hundreds of
/// shells accumulated in ~/Library/Preferences; `defaults delete` reports
/// such a domain as "not found" and leaves the file. The purge therefore
/// records every removed domain, and the final sweep — run once, at the
/// end of the selftest — waits for each recorded shell to become empty
/// (or vanish) and unlinks it. Guarded by name prefix so it can never touch
/// a real domain.
enum TestPrefsDomains {
    /// Every prefix a selftest may use for a throwaway domain. The smoke
    /// suite counts files matching these before and after a run.
    static let testPrefixes = ["ada-mig-probe-", "ada-mig-st-", "ada-setup-api-selftest-",
                               "briglia-s4-", "briglia-mw-"]

    static func isTestDomain(_ name: String) -> Bool {
        testPrefixes.contains { name.hasPrefix($0) }
    }

    private static let lock = NSLock()
    private static var purged: [String] = []

    /// Candidate on-disk locations of a domain's plist: the passwd home and
    /// $HOME (corelibs persists under $HOME, which differs from the passwd
    /// home on hosted CI containers).
    static func candidatePaths(_ name: String) -> [String] {
        var homes = [FileManager.default.homeDirectoryForCurrentUser.path]
        if let envHome = ProcessInfo.processInfo.environment["HOME"], !envHome.isEmpty,
           !homes.contains(envHome) {
            homes.append(envHome)
        }
        var out: [String] = []
        for home in homes {
            out += [home + "/Library/Preferences/\(name).plist",
                    home + "/.config/\(name).plist",
                    home + "/.local/share/\(name).plist"]
        }
        return out
    }

    /// Remove the domain now and remember it for the final sweep.
    static func purge(_ name: String) {
        guard isTestDomain(name) else { return }
        let defaults = UserDefaults.standard
        defaults.removePersistentDomain(forName: name)
        defaults.synchronize()
        lock.lock(); defer { lock.unlock() }
        if !purged.contains(name) { purged.append(name) }
    }

    /// Unlink every empty shell with a test prefix whose modification time
    /// is older than `olderThan` seconds, in every candidate preferences
    /// directory. Files holding data are never touched.
    static func sweepStaleShells(olderThan: TimeInterval) {
        let fm = FileManager.default
        var dirs: [String] = []
        for path in candidatePaths("x") {
            dirs.append((path as NSString).deletingLastPathComponent)
        }
        for dir in Set(dirs) {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in names where name.hasSuffix(".plist") && isTestDomain(name) {
                let path = dir + "/" + name
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let mtime = attrs[.modificationDate] as? Date,
                      Date().timeIntervalSince(mtime) > olderThan,
                      isEmptyShell(path) else { continue }
                _ = unlink(path)
            }
        }
    }

    /// True when the file at `path` is gone or holds an empty plist
    /// dictionary (the shell) — i.e. nothing is left to preserve.
    private static func isEmptyShellOrGone(_ path: String) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return true }
        guard let data = fm.contents(atPath: path) else { return false }
        if data.isEmpty { return true }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else {
            return false
        }
        if let dict = plist as? [String: Any] { return dict.isEmpty }
        return false
    }

    /// True when the file at `path` holds an empty plist dictionary (the
    /// shell) or no bytes — nothing left to preserve.
    private static func isEmptyShell(_ path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path) else { return false }
        if data.isEmpty { return true }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else {
            return false
        }
        if let dict = plist as? [String: Any] { return dict.isEmpty }
        return false
    }

    /// Wait (bounded) for every purged domain's on-disk shell to APPEAR and
    /// unlink it. A domain whose file is merely absent is not done: right
    /// after `removePersistentDomain` the file is typically gone, and the
    /// shell is written a few seconds later — treating "gone" as finished is
    /// exactly how shells leaked past the first version of this sweep. A
    /// domain whose shell never materializes within the timeout has nothing
    /// to clean. Returns the names still holding data after the timeout —
    /// the caller reports them; they also fail the smoke suite's count check.
    @discardableResult
    static func finalSweep(timeout: TimeInterval = 30) -> [String] {
        // Self-healing first: a shell that cfprefsd wrote AFTER an earlier
        // run's sweep gave up (seen once under heavy load: >12 s) is by
        // construction a throwaway domain — the prefixes are reserved for
        // tests — so any stale empty shell older than a minute is removed
        // before this run's own bookkeeping.
        sweepStaleShells(olderThan: 60)
        lock.lock()
        let names = purged
        lock.unlock()
        guard !names.isEmpty else { return [] }
        let fm = FileManager.default
        let deadline = Date().addingTimeInterval(timeout)
        var pending = Set(names)
        while !pending.isEmpty, Date() < deadline {
            for name in Array(pending) {
                let existing = candidatePaths(name).filter { fm.fileExists(atPath: $0) }
                guard !existing.isEmpty else { continue }          // shell not written yet — keep waiting
                if existing.allSatisfy(isEmptyShell) {
                    existing.forEach { _ = unlink($0) }
                    pending.remove(name)
                }
            }
            if !pending.isEmpty { usleep(200_000) }
        }
        var holdingData: [String] = []
        for name in pending {
            let existing = candidatePaths(name).filter { fm.fileExists(atPath: $0) }
            if existing.isEmpty { continue }                        // never materialized — nothing to clean
            if existing.allSatisfy(isEmptyShell) {
                existing.forEach { _ = unlink($0) }
            } else {
                holdingData.append(name)
            }
        }
        lock.lock(); purged.removeAll(); lock.unlock()
        return holdingData.sorted()
    }
}
