import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Authorization of the local settings pages (`briglia menu`, the live hub,
/// browser settings): a single-use launch token (5 minutes) exchanged for an
/// HttpOnly cookie, and a generation that every write re-checks. Enter in
/// the terminal (or a new link from the running Briglia) rotates: the old
/// cookie and token stop working at once, work of the old generation is
/// cancelled and settled, then a new link is minted.
///
/// This is the authorization half of the former browser Quick Setup's
/// workflow actor (retired in 0.2.67, when `briglia quicksetup` became a
/// terminal flow); the behaviour is unchanged.
actor PageAuthorizer {
    struct Superseded: Error {}

    /// The shared installer runner: a rotation cancels and reaps its job.
    let runner: SetupJobRunner

    private(set) var generation = 1
    /// nil after a rotation whose randomness failed: nothing can exchange.
    private var token: String?
    private var tokenIssuedAt = Date()
    private var tokenUsed = false
    private var cookie: String
    /// Operations of the current generation still executing: rotation waits
    /// for them to unwind at their next checkpoint before proceeding.
    private var inFlight = 0
    private(set) var consumedByOther = false
    static let tokenLifetime: TimeInterval = 300
    nonisolated(unsafe) static var clock: () -> Date = { Date() }

    init(runner: SetupJobRunner) throws {
        self.runner = runner
        guard let t = Self.randomHex(), let c = Self.randomHex() else {
            throw NSError(domain: "briglia.page", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot generate a secure link on this system."])
        }
        token = t
        cookie = c
    }

    /// Selftest seam: simulate RNG failure.
    nonisolated(unsafe) static var randomHexFails = false

    static func randomHex() -> String? {
        if randomHexFails { return nil }
        var bytes = [UInt8](repeating: 0, count: 16)
        #if os(Linux)
        // The Glibc module does not export getrandom(2); /dev/urandom is
        // the same CSPRNG pool. Any failure (missing device, short read)
        // aborts the command before listening — never a weaker fallback.
        let fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var filled = 0
        while filled < bytes.count {
            let n = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress! + filled, $0.count - filled) }
            if n < 0 { if errno == EINTR { continue }; return nil }
            if n == 0 { return nil }
            filled += n
        }
        #else
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        #endif
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Authorization

    /// The live launch token; empty when none can be issued (RNG failure).
    var launchToken: String { token ?? "" }
    var currentCookie: String { cookie }

    /// `GET /start?t=`: single use, 5-minute lifetime, current generation.
    func exchange(token candidate: String) -> String? {
        guard let token, !tokenUsed, candidate == token, Self.clock().timeIntervalSince(tokenIssuedAt) <= Self.tokenLifetime else {
            if candidate == token && tokenUsed { consumedByOther = true }
            return nil
        }
        tokenUsed = true
        return cookie
    }

    /// Atomic authorization: the cookie check and the generation it
    /// authorizes are one actor call, so a rotation between "cookie is
    /// current" and "which generation" cannot hand an old cookie the new
    /// generation.
    func authorizedGeneration(cookie candidate: String?) -> Int? {
        guard let candidate, candidate == cookie else { return nil }
        return generation
    }

    func authorized(cookie candidate: String?) -> Bool { authorizedGeneration(cookie: candidate) != nil }

    private func beginOperation() { inFlight += 1 }
    private func endOperation() { inFlight -= 1 }

    /// Wait (bounded) until every operation of the revoked generation has
    /// unwound at its next checkpoint.
    private func settleInFlight() async {
        var waited = 0
        while inFlight > 0, waited < 600 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            waited += 1
        }
    }
    var inFlightOperations: Int { inFlight }
    func beginSettingsOperation(_ g: Int) throws { try checkpoint(g); beginOperation() }
    func endSettingsOperation() { endOperation() }

    func checkpoint(_ g: Int) throws {
        if g != generation { throw Superseded() }
    }

    /// Generation snapshot readable without actor hops (the apply seam's
    /// checkpoint runs synchronously inside the section).
    private nonisolated let generationBox = GenerationBox()
    private final class GenerationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 1
        func set(_ v: Int) { lock.lock(); value = v; lock.unlock() }
        func get() -> Int { lock.lock(); defer { lock.unlock() }; return value }
    }
    nonisolated func checkpointSync(_ g: Int) throws {
        if generationBox.get() != g { throw SetupAPICore.CheckpointRevoked("this settings page session was replaced") }
    }

    /// Enter in the terminal: revoke, cancel + reap the running job, mint.
    struct RotationResult {
        var poison: SetupJobRunner.Poison?
        /// Fresh randomness could not be obtained: the old authorization is
        /// revoked and NO new link exists (the command must report it).
        var randomnessFailed = false
    }

    /// Rotations are serialized: a second Enter while one is in progress
    /// waits for it (its own revocation is already effective — nothing is
    /// authorized between the first revocation and the final mint).
    private var rotating = false
    private var rotationWaiters: [CheckedContinuation<Void, Never>] = []

    /// Work owned by a host of this authorizer (the `briglia menu` page)
    /// that must be cancelled and settled before a new link is minted.
    /// Lock-held so a router can attach it synchronously.
    private nonisolated let revocationHookBox = RevocationHookBox()
    final class RevocationHookBox: @unchecked Sendable {
        private let lock = NSLock()
        private var hook: (@Sendable () async -> Void)?
        func set(_ h: @escaping @Sendable () async -> Void) { lock.lock(); hook = h; lock.unlock() }
        func get() -> (@Sendable () async -> Void)? { lock.lock(); defer { lock.unlock() }; return hook }
    }
    nonisolated func setRevocationHook(_ hook: @escaping @Sendable () async -> Void) { revocationHookBox.set(hook) }

    func rotate() async -> RotationResult {
        // (1) REVOKE FIRST, before any await: no cookie authorizes, no token
        // exchanges, every checkpoint of the old generation throws. An
        // old-cookie request arriving during the cancellation window below
        // finds nothing to authorize and cannot inherit the new generation.
        generation += 1
        generationBox.set(generation)
        cookie = ""
        token = nil
        tokenUsed = true
        if rotating {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in rotationWaiters.append(c) }
            return RotationResult(poison: runner.currentPoison, randomnessFailed: token == nil)
        }
        rotating = true
        defer {
            rotating = false
            let waiters = rotationWaiters
            rotationWaiters = []
            for w in waiters { w.resume() }
        }
        if runner.currentJob != nil { print("cancelling the current step…") }
        let poison = await runner.cancelRunning()  // (2) confirmed reaping or poison
        await settleInFlight()                     // (3) suspended operations unwound
        if let hook = revocationHookBox.get() { await hook() }   // e.g. the menu's own work
        // (4) mint — or abort: the revoked token/cookie were already cleared.
        guard let newToken = Self.randomHex(), let newCookie = Self.randomHex() else {
            return RotationResult(poison: poison, randomnessFailed: true)
        }
        token = newToken
        cookie = newCookie
        tokenIssuedAt = Self.clock()
        tokenUsed = false
        consumedByOther = false
        return RotationResult(poison: poison)
    }
}
