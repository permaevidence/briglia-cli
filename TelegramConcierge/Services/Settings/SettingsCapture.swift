import Foundation

/// Preparation of a settings change (KEYLESS_WEB_AND_LIVE_MENU plan B.4).
///
/// The existing request code (`SetupAPICore.apply`, `SubscriptionSetup`,
/// the wizard's sections, a sign-in's final commit) runs unchanged inside
/// `prepare`, with a task-local overlay in front of the secret store: reads
/// see the store as it was plus this request's own edits, writes land in the
/// overlay only. Identity reservations, subscription-store writes and the
/// private AgentMail wipe are recorded instead of executed. The result is a
/// pure description — the secrets keys to set and delete, the preconditions
/// (the digest of every key it explicitly wrote or read via `load`; the
/// whole store's values for a dictionary transaction), the identity and subscription
/// operations — that `SettingsWriter` commits in the owner.
///
/// The overlay is task-local: other tasks of the same process (a running
/// turn in the daemon) keep reading and writing the real store.
final class SettingsCaptureBox: @unchecked Sendable {
    private let lock = NSLock()
    let base: [String: String]
    private var overlay: [String: String]
    private var reads = Set<String>()
    private var touched = Set<String>()
    private var wholeStoreRead = false
    /// A dictionary transaction ran: its reads are not observable, so the
    /// whole store's values are its basis (Codex live-menu R1-7).
    private var transactionRead = false
    /// Evaluation mode (pure resolvers over a dictionary): writes throw.
    let readOnly: Bool
    private var identityOp: SettingsIdentityOp?
    private var subscriptionOp: SettingsSubscriptionOp?
    private var expectations: [SettingsSubscriptionExpectation] = []
    private var wipeInstall = false
    private var webMirror: String?
    private var refusal: String?
    /// A login published from this change re-checks the active-login
    /// replacement guard at commit (the menu sets it).
    var guardActiveLogin = false

    init(base: [String: String], readOnly: Bool = false) {
        self.base = base
        self.overlay = base
        self.readOnly = readOnly
    }

    struct ReadOnlyWrite: Error, CustomStringConvertible {
        var description: String { "a pure settings resolver tried to write the store" }
    }

    func load(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        reads.insert(key)
        return overlay[key]
    }

    func snapshot() -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        wholeStoreRead = true
        return overlay
    }

    /// Explicit key writes (`save`, `delete`, `saveBatch`): every named key
    /// is recorded as written — even when the value does not change — so a
    /// save of the current value still re-checks it at commit.
    func write(_ changes: [String: String?]) throws {
        if readOnly { throw ReadOnlyWrite() }
        lock.lock(); defer { lock.unlock() }
        for (key, value) in changes {
            touched.insert(key)
            if let value { overlay[key] = value } else { overlay.removeValue(forKey: key) }
        }
    }

    func mutate(_ change: (inout [String: String]) throws -> Void, skipUnchanged: Bool, wrote: inout Bool) throws {
        if readOnly { throw ReadOnlyWrite() }
        lock.lock()
        var next = overlay
        transactionRead = true
        lock.unlock()
        // The closure may read the store (the real store does not allow it;
        // the overlay does no harm) — it runs outside the box lock.
        try change(&next)
        lock.lock(); defer { lock.unlock() }
        let before = overlay
        for (k, v) in next where before[k] != v { touched.insert(k) }
        for k in before.keys where next[k] == nil { touched.insert(k) }
        overlay = next
        wrote = next != before
    }

    // MARK: Recorded operations

    func recordIdentity(_ op: SettingsIdentityOp) {
        lock.lock(); defer { lock.unlock() }
        if identityOp != nil && identityOp != op { refusal = "one settings change can hold only one bot or inbox change" }
        identityOp = op
    }

    func recordSubscription(_ op: SettingsSubscriptionOp) {
        lock.lock(); defer { lock.unlock() }
        if subscriptionOp != nil { refusal = "one settings change can hold only one ChatGPT login operation" }
        subscriptionOp = op
    }

    /// The auth state a preparation read (nil generation = absent store):
    /// one basis per store, the last read wins (the preparation's own flow
    /// state writes never change the generation).
    func recordSubscriptionBasis(store: String, generation: String?) {
        lock.lock(); defer { lock.unlock() }
        let path = URL(fileURLWithPath: store).standardizedFileURL.path
        expectations.removeAll { $0.basis && URL(fileURLWithPath: $0.store).standardizedFileURL.path == path }
        var e = SettingsSubscriptionExpectation(store: store, generation: generation ?? "", requireUsable: false, requireNoPending: false)
        e.basis = true
        expectations.append(e)
    }

    /// The auth state this preparation will publish (Codex R2-1): later
    /// reads of that store inside the same preparation see the projected
    /// login, while the recorded basis stays the real one.
    private var projected: [String: SubscriptionAuthState] = [:]

    func projectAuth(store: String, _ state: SubscriptionAuthState) {
        lock.lock(); defer { lock.unlock() }
        projected[URL(fileURLWithPath: store).standardizedFileURL.path] = state
    }

    func projectedAuth(store: String) -> SubscriptionAuthState? {
        lock.lock(); defer { lock.unlock() }
        return projected[URL(fileURLWithPath: store).standardizedFileURL.path]
    }

    /// A selection consumed "usable" (and maybe "no pending login"): checked
    /// again under the auth lock (Codex R2-3). Not recorded for the login
    /// this change itself publishes (its publish op is validated instead).
    func expectUsableLogin(store: String, generation: String, requireNoPending: Bool) {
        if projectedAuth(store: store)?.generation == generation { return }
        expectSubscription(SettingsSubscriptionExpectation(store: store, generation: generation,
                                                           requireUsable: true, requireNoPending: requireNoPending))
    }

    func expectSubscription(_ expectation: SettingsSubscriptionExpectation) {
        lock.lock(); defer { lock.unlock() }
        if !expectations.contains(expectation) { expectations.append(expectation) }
    }

    func recordAgentMailInstallWipe() {
        lock.lock(); defer { lock.unlock() }
        wipeInstall = true
    }

    func recordWebBackendMirror(_ raw: String) {
        lock.lock(); defer { lock.unlock() }
        webMirror = raw
    }

    // MARK: Result

    func makeChange(origin: String, label: String, epoch: Int, acceptPending: Bool,
                    reply: [String: Any]?) throws -> PreparedChange {
        lock.lock(); defer { lock.unlock() }
        if let refusal { throw SettingsCommitError.refused(refusal) }
        var change = PreparedChange(origin: origin, label: label, epoch: epoch)
        for (k, v) in overlay where base[k] != v { change.writes[k] = v }
        change.deletes = base.keys.filter { overlay[$0] == nil }.sorted()
        // Preconditions: every key written (even back to its own value) or
        // read, digested as it was when preparation started.
        for key in touched.union(reads).union(change.touchedKeys) {
            change.expected[key] = SettingsDigest.of(base[key])
        }
        if wholeStoreRead { change.routeDigest = SettingsKeyRoles.routeDigest(base) }
        if transactionRead { change.storeDigest = SettingsDigest.ofStore(base) }
        // Written keys whose net value did not change: nothing to write, but
        // the commit still validates them (and any transaction basis).
        if change.writes.isEmpty, change.deletes.isEmpty, !touched.isEmpty || transactionRead { change.validateOnly = true }
        change.identity = identityOp
        change.subscription = subscriptionOp
        change.subscriptionExpectations = expectations
        change.wipeAgentMailInstall = wipeInstall
        change.webBackendMirror = webMirror
        change.category = SettingsKeyRoles.category(of: change)
        change.acceptPending = acceptPending
        if let reply { change.reply = PreparedChange.jsonText(reply) }
        return change
    }
}

enum SettingsCapture {
    @TaskLocal static var current: SettingsCaptureBox?

    /// True while the current task prepares a change (writes go to the overlay).
    static var isCapturing: Bool { current.map { !$0.readOnly } ?? false }

    /// Runs `body` (the existing request code) against an overlay of the
    /// current on-disk store and returns its reply together with the
    /// prepared change. A reply that reports failure (`ok: false`) is
    /// returned with `change == nil`: nothing is committed, and its
    /// `applied` list is emptied (all-or-nothing now).
    static func prepare(origin: String, label: String, acceptPending: Bool = false,
                        _ body: () async -> [String: Any]) async -> (change: PreparedChange?, reply: [String: Any]) {
        let epoch: Int
        let base: [String: String]
        do {
            epoch = try ReplacementEpoch.read()
            base = try KeychainHelper.strictSnapshot()
        } catch {
            return (nil, SetupAPICore.errorResponse(code: "settings_unreadable", message: "\(error)"))
        }
        let box = SettingsCaptureBox(base: base)
        var reply = await $current.withValue(box) { await body() }
        guard reply["ok"] as? Bool != false else {
            if reply["applied"] != nil { reply["applied"] = [String]() }
            return (nil, reply)
        }
        do {
            let change = try box.makeChange(origin: origin, label: label, epoch: epoch,
                                            acceptPending: acceptPending, reply: reply)
            return (change, reply)
        } catch {
            return (nil, SetupAPICore.errorResponse(code: "invalid_change", message: "\(error)"))
        }
    }

    /// Throwing variant for callers whose body throws (sign-in commits).
    static func prepareThrowing<T>(origin: String, label: String, acceptPending: Bool = false, guardActiveLogin: Bool = false,
                                   _ body: () async throws -> T) async throws -> (change: PreparedChange, value: T) {
        let epoch = try ReplacementEpoch.read()
        let base = try KeychainHelper.strictSnapshot()
        let box = SettingsCaptureBox(base: base)
        box.guardActiveLogin = guardActiveLogin
        let value = try await $current.withValue(box) { try await body() }
        let change = try box.makeChange(origin: origin, label: label, epoch: epoch, acceptPending: acceptPending, reply: nil)
        return (change, value)
    }

    /// Evaluates `body` with every KeychainHelper read answered from `store`
    /// (and writes refused): the request path's own resolvers become pure
    /// functions of a dictionary (plan B.4 `RouteSnapshot`).
    static func evaluate<T>(store: [String: String], _ body: () throws -> T) rethrows -> T {
        try $current.withValue(SettingsCaptureBox(base: store, readOnly: true)) { try body() }
    }
}
