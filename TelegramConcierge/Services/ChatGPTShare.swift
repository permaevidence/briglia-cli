import Foundation

/// The machine sharing lock of the one shared ChatGPT login
/// (MULTI_ASSISTANT_PLAN §25.11): `<default data root>/machine/chatgpt-share.lock`
/// serialises every change of WHO shares the machine store (`profiles add`,
/// `profiles remove`, a scope change, a Mind import that resets a scope) with
/// the decisions that depend on it (default's wipe signing the store out).
/// Lock order: `identity-tx.lock` → `chatgpt-share.lock` → `registry.lock`
/// (taken inside, never held across an await) → `subscription-auth.lock` →
/// `secrets.lock`.
enum ChatGPTShare {
    static var lockURL: URL { MachinePaths.machineDir().appendingPathComponent("chatgpt-share.lock") }
    static let waitSeconds: Double = 10
    static let busyMessage = "Another assistant is changing its ChatGPT setting right now — try again in a moment."

    struct Busy: Error, CustomStringConvertible { let description = ChatGPTShare.busyMessage }

    /// Bounded wait; throws `Busy` on timeout.
    static func takeLock(wait: Double = waitSeconds, url: URL? = nil) throws -> ProfileFileLock? {
        if url == nil { try MachinePaths.ensureMachineDir() }
        switch ProfileFileLock.take(url ?? lockURL, waitSeconds: wait) {
        case .acquired(let l): return l
        case .busy: throw Busy()
        case .failed(let why): throw ProfileLifecycle.LifecycleError(why)
        }
    }
}
