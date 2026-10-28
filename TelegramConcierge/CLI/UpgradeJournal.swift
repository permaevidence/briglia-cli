import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// The release sequence of the binary+bundle pair this process runs from
/// (MULTI_ASSISTANT_PLAN §5.1, §6). Normally the compiled-in sequence. In a
/// development build, with `BRIGLIA_TEST_BUNDLE_SEQUENCE=1`, it is read from
/// `<bundle next to the executable>/test-release-sequence`, so a barrier test
/// can install a "newer" pair made from the same binary.
enum ReleaseSequence {
    static let testKey = "BRIGLIA_TEST_BUNDLE_SEQUENCE"
    static let testFileName = "test-release-sequence"

    static func of(executable: URL) -> Int {
        guard adaCLIVersion.hasSuffix("-dev"), ProcessInfo.processInfo.environment[testKey] == "1" else {
            return adaCLIReleaseSequence
        }
        let file = executable.deletingLastPathComponent().appendingPathComponent(BundleCheck.bundleName)
            .appendingPathComponent(testFileName)
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let n = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return adaCLIReleaseSequence }
        return n
    }

    /// This running image (read once: the exec'd image reads it again).
    static let compiled: Int = of(executable: UpgradeService.executableURL)
}

/// A downloaded, verified pair waiting to be installed.
struct StagedUpgrade {
    var version: String
    var sequence: Int
    var binary: URL
    var bundle: URL
    /// Removed by the caller when the upgrade ends.
    var tempDirectory: URL?
}

/// The publication journal and swap (§6.3 step 7) and the recovery table
/// (§6.5). Every journal transition is an atomic write with file and parent
/// fsync; backups of the old pair are KEPT until the barrier closes.
enum UpgradeJournal {
    struct Failure: Error, CustomStringConvertible { let description: String; init(_ d: String) { description = d } }

    /// Dev-only kill points (`BRIGLIA_UPGRADE_KILL=<point>`): the process
    /// exits at once, like a crash, so recovery can be tested.
    static func killPoint(_ name: String) {
        guard adaCLIVersion.hasSuffix("-dev"), ProcessInfo.processInfo.environment["BRIGLIA_UPGRADE_KILL"] == name else { return }
        FileHandle.standardError.write(Data("[test] killed at \(name)\n".utf8))
        _exit(91)
    }

    static func names(barrierId: String, installDir: URL) -> (stagedBinary: URL, stagedBundle: URL, backupBinary: URL, backupBundle: URL) {
        let tag = String(barrierId.prefix(12))
        return (installDir.appendingPathComponent(".briglia-upgrade-staged-\(tag)-bin"),
                installDir.appendingPathComponent(".briglia-upgrade-staged-\(tag)-bundle"),
                installDir.appendingPathComponent(".briglia-upgrade-backup-\(tag)-bin"),
                installDir.appendingPathComponent(".briglia-upgrade-backup-\(tag)-bundle"))
    }

    /// Run the installed binary's resource check as an exempt installer
    /// probe (it carries the barrier token; valid only while this process
    /// holds `upgrade.lock` for that barrier).
    static func probeInstalled(_ binary: URL, barrierId: String) -> Bool {
        let p = Process()
        p.executableURL = binary
        p.arguments = ["bundle-check"]
        var env = ProcessInfo.processInfo.environment
        env["BRIGLIA_UPGRADE_PROBE"] = barrierId
        env.removeValue(forKey: AssistantProfile.environmentKey)
        p.environment = env
        p.currentDirectoryURL = URL(fileURLWithPath: "/")
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// prepared → moving → placed → verified. The caller then writes
    /// `installed.json`, commits the journal and the barrier (§6.3 step 8).
    static func swap(_ staged: StagedUpgrade, barrierId: String, executable: URL,
                     paths: UpgradeBarrier.Paths = .live) throws -> UpgradeBarrier.Journal {
        let fm = FileManager.default
        let installDir = executable.deletingLastPathComponent()
        let bundle = installDir.appendingPathComponent(BundleCheck.bundleName)
        guard let old = UpgradeBarrier.identity(binary: executable, bundle: bundle),
              let new = UpgradeBarrier.identity(binary: staged.binary, bundle: staged.bundle) else {
            throw Failure("cannot read the installed or the downloaded build; nothing was changed")
        }
        let n = names(barrierId: barrierId, installDir: installDir)
        for leftover in [n.stagedBinary, n.stagedBundle] { try? fm.removeItem(at: leftover) }
        // Stage in the install directory (same-volume renames below).
        try fm.copyItem(at: staged.binary, to: n.stagedBinary)
        try fm.copyItem(at: staged.bundle, to: n.stagedBundle)
        var j = UpgradeBarrier.Journal(barrierId: barrierId, phase: .prepared, nextStep: nil, old: old, new: new,
                                       newVersion: staged.version, newSequence: staged.sequence,
                                       executable: executable.path, bundle: bundle.path,
                                       backupBinary: n.backupBinary.path, backupBundle: n.backupBundle.path,
                                       stagedBinary: n.stagedBinary.path, stagedBundle: n.stagedBundle.path,
                                       bundleExisted: fm.fileExists(atPath: bundle.path))
        try UpgradeBarrier.writeJournal(j, paths)
        killPoint("prepared")
        func step(_ name: String, _ body: () throws -> Void) throws {
            j.phase = .moving; j.nextStep = name
            try UpgradeBarrier.writeJournal(j, paths)
            try body()
            killPoint("moved-\(name)")
        }
        try step("binary-aside") { try fm.moveItem(at: executable, to: n.backupBinary) }
        if j.bundleExisted { try step("bundle-aside") { try fm.moveItem(at: bundle, to: n.backupBundle) } }
        try step("binary-in") { try fm.moveItem(at: n.stagedBinary, to: executable) }
        try step("bundle-in") { try fm.moveItem(at: n.stagedBundle, to: bundle) }
        j.phase = .placed; j.nextStep = nil
        try UpgradeBarrier.writeJournal(j, paths)
        killPoint("placed")
        guard verifyPair(j, expect: j.new) else { throw Failure("the installed build does not match the download") }
        guard probeInstalled(executable, barrierId: barrierId) else { throw Failure("the installed build failed its resource check") }
        j.phase = .verified
        try UpgradeBarrier.writeJournal(j, paths)
        killPoint("verified")
        return j
    }

    static func verifyPair(_ j: UpgradeBarrier.Journal, expect: UpgradeBarrier.Identity) -> Bool {
        UpgradeBarrier.identity(binary: URL(fileURLWithPath: j.executable), bundle: URL(fileURLWithPath: j.bundle)) == expect
    }

    /// §6.3 step 8: installed.json, then journal committed, then barrier
    /// committed — each idempotent.
    static func commit(_ j: UpgradeBarrier.Journal, barrier: inout UpgradeBarrier.Record,
                       paths: UpgradeBarrier.Paths = .live) throws {
        var j = j
        let installed = UpgradeBarrier.Installed(version: j.newVersion, sequence: j.newSequence, executable: j.executable,
                                                 binarySHA256: j.new.binarySHA256, bundleHash: j.new.bundleHash)
        try UpgradeBarrier.writeFile(installed, to: paths.installed)
        killPoint("installed")
        j.phase = .committed
        try UpgradeBarrier.writeJournal(j, paths)
        killPoint("journal-committed")
        barrier.state = .committed
        barrier.committedBinarySHA256 = j.new.binarySHA256
        try UpgradeBarrier.writeBarrier(barrier, paths)
        killPoint("barrier-committed")
    }

    /// Put the old pair back from the recorded backups/staged paths, then
    /// verify it against `journal.old`. Never guesses a path.
    static func restoreOld(_ j: UpgradeBarrier.Journal) -> Bool {
        let fm = FileManager.default
        let exe = URL(fileURLWithPath: j.executable), bundle = URL(fileURLWithPath: j.bundle)
        let backupBin = URL(fileURLWithPath: j.backupBinary), backupBundle = URL(fileURLWithPath: j.backupBundle)
        if fm.fileExists(atPath: backupBin.path) {
            try? fm.removeItem(at: exe)
            guard (try? fm.moveItem(at: backupBin, to: exe)) != nil else { return false }
        }
        killPoint("recovery-binary-restored")
        if j.bundleExisted, fm.fileExists(atPath: backupBundle.path) {
            try? fm.removeItem(at: bundle)
            guard (try? fm.moveItem(at: backupBundle, to: bundle)) != nil else { return false }
        }
        try? fm.removeItem(at: URL(fileURLWithPath: j.stagedBinary))
        try? fm.removeItem(at: URL(fileURLWithPath: j.stagedBundle))
        return verifyPair(j, expect: j.old)
    }

    /// Closure cleanup: backups and journal go.
    static func cleanup(_ paths: UpgradeBarrier.Paths = .live) {
        if case .value(let j) = UpgradeBarrier.journal(paths) {
            for p in [j.backupBinary, j.backupBundle, j.stagedBinary, j.stagedBundle] { try? FileManager.default.removeItem(atPath: p) }
        }
        try? FileManager.default.removeItem(at: paths.journal)
    }

    // MARK: Recovery (§6.5)

    enum RecoveryOutcome: Equatable {
        case nothing(String)
        case cancelled(String)
        case committed(String)
        case closedCleanup
        case stuck(String)
        case malformed(String)
    }

    /// The decision table over (journal phase × barrier state). The caller
    /// holds `upgrade.lock` and has re-read the barrier. `allowStuck`: only
    /// `briglia upgrade --recover` acts on a stuck barrier.
    static func recover(_ barrierIn: UpgradeBarrier.Record, allowStuck: Bool,
                        paths: UpgradeBarrier.Paths = .live,
                        probe: (URL, String) -> Bool = probeInstalled) -> RecoveryOutcome {
        var barrier = barrierIn
        let journal: UpgradeBarrier.Journal?
        switch UpgradeBarrier.journal(paths) {
        case .absent: journal = nil
        case .value(let j):
            guard j.barrierId == barrier.id else { return .malformed("the update journal belongs to another update (\(j.barrierId)); nothing was changed") }
            journal = j
        case .malformed(let why): return .malformed(why)
        }
        func write(_ state: UpgradeBarrier.State, _ reason: String? = nil) -> Bool {
            barrier.state = state
            if let reason { barrier.reason = reason }
            return (try? UpgradeBarrier.writeBarrier(barrier, paths)) != nil
        }
        func reverify(_ j: UpgradeBarrier.Journal) -> Bool {
            verifyPair(j, expect: j.new) && probe(URL(fileURLWithPath: j.executable), barrier.id)
        }
        func finishCommit(_ j: UpgradeBarrier.Journal) -> RecoveryOutcome {
            do { try commit(j, barrier: &barrier, paths: paths) } catch { return .stuck("could not record the finished update: \(error)") }
            return .committed("the new version \(j.newVersion) was already installed; the update is finished")
        }
        func rollBack(_ j: UpgradeBarrier.Journal) -> RecoveryOutcome {
            if restoreOld(j) {
                _ = write(.cancelled, "rolled back after an interrupted update")
                try? FileManager.default.removeItem(at: paths.journal)
                return .cancelled("the interrupted update was undone; the previous version is installed")
            }
            _ = write(.stuck, "restoring the previous version failed")
            return .stuck("restoring the previous version failed; restore \(j.executable) from \(j.backupBinary) and \(j.bundle) from \(j.backupBundle)")
        }
        switch barrier.state {
        case .closed:
            cleanup(paths)
            return .closedCleanup
        case .cancelled:
            return .nothing("no update is in progress")
        case .stuck where !allowStuck:
            return .stuck(UpgradeBarrier.stuckMessage)
        case .open, .committed, .stuck:
            break
        }
        guard let j = journal else {
            switch barrier.state {
            case .open:
                _ = write(.cancelled, "the update stopped before installing anything")
                return .cancelled("the interrupted update had not installed anything")
            case .committed:
                return .nothing("the update is finished; assistants are restarting")
            default:
                // R5-3: a stuck barrier without its journal stays stuck.
                return .stuck("the update journal is missing; nothing can be verified. Reinstall Briglia with the installer, then remove \(paths.barrier.path)")
            }
        }
        switch (j.phase, barrier.state) {
        case (.prepared, .open), (.moving, .open), (.placed, .open):
            return rollBack(j)
        case (.verified, .open), (.committed, .open):
            // Re-verify the installed pair against `journal.new`; success
            // completes the idempotent commit writes (installed.json, journal,
            // barrier); failure → stuck (a committed journal is never treated
            // as an untouched install).
            guard reverify(j) else {
                _ = write(.stuck, "the installed build failed verification")
                return .stuck("the installed build failed verification; run `briglia upgrade --recover`")
            }
            return finishCommit(j)
        case (.committed, .committed):
            return .nothing("the update is finished; assistants are restarting")
        case (.prepared, .stuck), (.moving, .stuck), (.placed, .stuck):
            return rollBack(j)
        case (.verified, .stuck), (.committed, .stuck):
            if reverify(j) { return finishCommit(j) }
            return rollBack(j)
        default:
            return .stuck("unexpected update state (\(j.phase.rawValue), \(barrier.state.rawValue))")
        }
    }
}
