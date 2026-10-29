import Foundation

/// The cross-process half of the intake stop (owner decision 2026-10-29;
/// Codex stage-3 S3-R14-1). The running assistant's restore gate stops every
/// in-process producer, but a separate Briglia process for the same profile
/// (`briglia setup-api apply`, `setup-api subscription`, `briglia trigger`,
/// `briglia subscription login|logout|…`) writes state a wipe deletes or an
/// import replaces — names, the AgentMail key and inbox, the ChatGPT login,
/// the trigger spool — without passing that gate.
///
/// One profile-scoped `flock`: with several assistants, `/deleteuserdata`
/// and Mind import hold it EXCLUSIVELY from their first busy check until the
/// gate drops (`endMindRestore`); each standalone writer holds it SHARED for
/// its whole run. Whoever is first wins: a writer already running makes the
/// replacement wait (bounded) and then refuse; a replacement in progress
/// makes the writer wait (bounded) and then refuse. A dead process releases
/// its lock with its file descriptors. With one assistant the exclusive side
/// is never taken, so standalone writers behave exactly as before.
enum MemoryReplacementLock {
    static var url: URL { StoragePaths.dataRoot.appendingPathComponent("memory-replacement.lock") }

    /// Non-blocking exclusive attempt (the manager polls it on its actor).
    static func tryExclusive() -> ProfileFileLock.Outcome {
        try? PrivateStorage.ensureDirectory(StoragePaths.dataRoot)
        return ProfileFileLock.take(url, waitSeconds: 0)
    }

    enum Admission { case admitted(ProfileFileLock?), busy, failed(String) }

    /// Standalone writers: bounded wait for a replacement to finish. Never
    /// creates a root: with no data root yet there is nothing a replacement
    /// could be deleting (and a pre-migration layout must stay untouched),
    /// so the writer is admitted without a lock.
    static func shared(waitSeconds: Double = 60) -> Admission {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: StoragePaths.dataRoot.path, isDirectory: &isDir), isDir.boolValue else {
            return .admitted(nil)
        }
        switch ProfileFileLock.take(url, waitSeconds: waitSeconds, shared: true) {
        case .acquired(let lock): return .admitted(lock)
        case .busy: return .busy
        case .failed(let why): return .failed(why)
        }
    }

    /// 60 s; development builds accept BRIGLIA_REPLACEMENT_WAIT_SECONDS for tests.
    static var standaloneWaitSeconds: Double {
        if adaCLIVersion.hasSuffix("-dev"),
           let raw = ProcessInfo.processInfo.environment["BRIGLIA_REPLACEMENT_WAIT_SECONDS"], let v = Double(raw) { return v }
        return 60
    }

    static let busyMessage = "Briglia is deleting or importing this assistant's memory right now; nothing was changed — try again when it finishes. / Briglia sta cancellando o importando la memoria di questo assistente; non è stato modificato nulla — riprova al termine."
}
