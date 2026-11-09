import Foundation

/// The commit token (KEYLESS_WEB_AND_LIVE_MENU plan B.4a step 1, B.4b): FIFO,
/// one holder at a time, not reentrant, handed out as a capability value.
/// Every in-owner settings write runs under it — the live hub, forwarded
/// commits, Telegram settings commands and buttons, subscription
/// publication, agent field edits, pending applies. Lifecycle operations
/// (Mind import, /deleteuserdata, shutdown, the upgrade barrier) close
/// admission, settle the waiters, cancel the holder's write-free wait and
/// then take the token themselves.
///
/// Not reentrant (0.2.70): a task that holds the token and asks for it again
/// would wait on itself forever (Telegram `/subscription login official`
/// deadlocked this way in 0.2.69). The writer therefore reuses the token for
/// writes made by the very task that acquired it (`tokenHeldByCurrentTask`),
/// and `acquire` refuses such a reentry at once instead of hanging. Other
/// tasks — including tasks spawned while the token is held, which inherit
/// task-local values — never match and queue as usual.
@MainActor
final class SettingsCommitGate {
    struct Token: Equatable, Sendable { fileprivate let id: UInt64 }

    /// `interrupting` (SIWC plan §3.9 R2): an SIWC sign-out has fenced this
    /// process's sends and is cancelling and draining the jobs of that login;
    /// like `durable`, it is never cancelled by a lifecycle operation, which
    /// waits for the holder instead.
    enum Phase { case preCommit, interrupting, durable }

    private var counter: UInt64 = 0
    private var holder: Token?
    /// The task that acquired `holder` (its identity, never a task-local).
    private var holderTask: Int?
    private var holderPhase: Phase = .preCommit
    private var holderCancel: (() -> Void)?
    private var waiters: [(id: UInt64, lifecycle: Bool, task: Int?, resume: CheckedContinuation<Token?, Never>)] = []
    private(set) var admissionClosedReason: String?

    var isHeld: Bool { holder != nil }
    var queued: Int { waiters.count }
    var holderInDurablePhase: Bool { holder != nil && holderPhase == .durable }

    /// Identity of the running task (unstructured and child tasks differ
    /// from their creator; nil outside a task).
    nonisolated static func currentTaskKey() -> Int? { withUnsafeCurrentTask { $0?.hashValue } }

    /// The token the CALLING task acquired itself and still holds, or nil.
    var tokenHeldByCurrentTask: Token? {
        guard let holder, let owner = holderTask, let me = Self.currentTaskKey(), owner == me else { return nil }
        return holder
    }

    /// Reentrant acquires refused (diagnostics and selftests).
    private(set) var reentryRefusals = 0

    /// Ordinary writers: nil = admission is closed (refused at once).
    func acquire() async -> Token? {
        if admissionClosedReason != nil { return nil }
        if tokenHeldByCurrentTask != nil {
            // Waiting here would wait on this task's own token forever.
            reentryRefusals += 1
            print("[SettingsCommitGate] refused a reentrant acquire: this task already holds the settings commit token (it would wait on itself forever)")
            return nil
        }
        return await enqueue(lifecycle: false)
    }

    /// Lifecycle operations: ignore closed admission (they closed it).
    func acquireForLifecycle() async -> Token {
        await enqueue(lifecycle: true) ?? { fatalError("lifecycle token wait settled") }()
    }

    private func enqueue(lifecycle: Bool) async -> Token? {
        counter &+= 1
        let id = counter
        let task = Self.currentTaskKey()
        if holder == nil && waiters.isEmpty {
            let token = Token(id: id)
            holder = token; holderTask = task; holderPhase = .preCommit; holderCancel = nil
            return token
        }
        return await withCheckedContinuation { continuation in
            waiters.append((id, lifecycle, task, continuation))
        }
    }

    func release(_ token: Token) {
        guard holder == token else { return }
        holder = nil; holderTask = nil; holderCancel = nil; holderPhase = .preCommit
        while !waiters.isEmpty {
            let next = waiters.removeFirst()
            if admissionClosedReason != nil && !next.lifecycle { next.resume.resume(returning: nil); continue }
            let token = Token(id: next.id)
            holder = token; holderTask = next.task; holderPhase = .preCommit; holderCancel = nil
            next.resume.resume(returning: token)
            return
        }
    }

    /// The holder's cancellable pre-commit wait (barrier, locks). Cleared by
    /// `enterDurablePhase`.
    func setCancelHandler(_ token: Token, _ handler: @escaping () -> Void) {
        guard holder == token, holderPhase == .preCommit else { return }
        holderCancel = handler
    }

    /// SIWC sign-out step 2: entered in the same main-actor step as the
    /// fence; from here the holder is never cancelled.
    func enterInterruptingPhase(_ token: Token) {
        guard holder == token else { return }
        holderPhase = .interrupting; holderCancel = nil
    }

    var holderInterrupting: Bool { holder != nil && holderPhase == .interrupting }

    /// Step 8 reached: from now on the holder is never cancelled.
    func enterDurablePhase(_ token: Token) {
        guard holder == token else { return }
        holderPhase = .durable; holderCancel = nil
    }

    /// B.4b steps 1–3: refuse new writers, settle every queued writer with
    /// a refusal, cancel the holder's write-free wait.
    func closeAdmission(reason: String) {
        admissionClosedReason = reason
        var kept: [(id: UInt64, lifecycle: Bool, task: Int?, resume: CheckedContinuation<Token?, Never>)] = []
        for w in waiters {
            if w.lifecycle { kept.append(w) } else { w.resume.resume(returning: nil) }
        }
        waiters = kept
        if holderPhase == .preCommit { holderCancel?() }
    }

    func reopenAdmission() { admissionClosedReason = nil }
}
