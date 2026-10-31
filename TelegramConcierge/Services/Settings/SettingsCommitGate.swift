import Foundation

/// The commit token (KEYLESS_WEB_AND_LIVE_MENU plan B.4a step 1, B.4b): FIFO,
/// one holder at a time, not reentrant, handed out as a capability value.
/// Every in-owner settings write runs under it — the live hub, forwarded
/// commits, Telegram settings commands and buttons, subscription
/// publication, agent field edits, pending applies. Lifecycle operations
/// (Mind import, /deleteuserdata, shutdown, the upgrade barrier) close
/// admission, settle the waiters, cancel the holder's write-free wait and
/// then take the token themselves.
@MainActor
final class SettingsCommitGate {
    struct Token: Equatable, Sendable { fileprivate let id: UInt64 }

    enum Phase { case preCommit, durable }

    private var counter: UInt64 = 0
    private var holder: Token?
    private var holderPhase: Phase = .preCommit
    private var holderCancel: (() -> Void)?
    private var waiters: [(id: UInt64, lifecycle: Bool, resume: CheckedContinuation<Token?, Never>)] = []
    private(set) var admissionClosedReason: String?

    var isHeld: Bool { holder != nil }
    var queued: Int { waiters.count }
    var holderInDurablePhase: Bool { holder != nil && holderPhase == .durable }

    /// Ordinary writers: nil = admission is closed (refused at once).
    func acquire() async -> Token? {
        if admissionClosedReason != nil { return nil }
        return await enqueue(lifecycle: false)
    }

    /// Lifecycle operations: ignore closed admission (they closed it).
    func acquireForLifecycle() async -> Token {
        await enqueue(lifecycle: true) ?? { fatalError("lifecycle token wait settled") }()
    }

    private func enqueue(lifecycle: Bool) async -> Token? {
        counter &+= 1
        let id = counter
        if holder == nil && waiters.isEmpty {
            let token = Token(id: id)
            holder = token; holderPhase = .preCommit; holderCancel = nil
            return token
        }
        return await withCheckedContinuation { continuation in
            waiters.append((id, lifecycle, continuation))
        }
    }

    func release(_ token: Token) {
        guard holder == token else { return }
        holder = nil; holderCancel = nil; holderPhase = .preCommit
        while !waiters.isEmpty {
            let next = waiters.removeFirst()
            if admissionClosedReason != nil && !next.lifecycle { next.resume.resume(returning: nil); continue }
            let token = Token(id: next.id)
            holder = token; holderPhase = .preCommit; holderCancel = nil
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

    /// Step 8 reached: from now on the holder is never cancelled.
    func enterDurablePhase(_ token: Token) {
        guard holder == token else { return }
        holderPhase = .durable; holderCancel = nil
    }

    /// B.4b steps 1–3: refuse new writers, settle every queued writer with
    /// a refusal, cancel the holder's write-free wait.
    func closeAdmission(reason: String) {
        admissionClosedReason = reason
        var kept: [(id: UInt64, lifecycle: Bool, resume: CheckedContinuation<Token?, Never>)] = []
        for w in waiters {
            if w.lifecycle { kept.append(w) } else { w.resume.resume(returning: nil) }
        }
        waiters = kept
        if holderPhase == .preCommit { holderCancel?() }
    }

    func reopenAdmission() { admissionClosedReason = nil }
}
