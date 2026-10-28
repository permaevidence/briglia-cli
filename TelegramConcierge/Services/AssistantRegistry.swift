import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// The machine registry of assistants and their bot/inbox reservations
/// (MULTI_ASSISTANT_PLAN v5 §5.6). It exists only once an extra profile was
/// added (`briglia-shared/registry.json`); a never-multi install has none and
/// every call here is then a no-op.
///
/// - One record per profile, default included. Bot ids and inbox addresses
///   are normalised and stored as SHA-256, never in clear.
/// - Every change runs under `registry.lock` (bounded 10 s wait), never
///   across a network await or a wait for another process. Lock order:
///   `machine/identity-tx.lock` → `registry.lock` → `secrets.lock`.
/// - A bot/inbox change is a transaction owned by a writer lease
///   (`tx/<txId>.lock`, flock held for the whole transaction): reserve
///   (`pending`) before any network use, commit (secret written, old value
///   moved to `releasing`), finish (release). Entries are tagged with their
///   `txId`; cleanup only ever touches entries whose writer lease is dead
///   and whose `txId` matches.
/// - Startup reconciliation (before any Telegram poll or AgentMail poll)
///   adopts a value that is not in the record when it is free, and refuses
///   the channel when another assistant holds it.
enum AssistantRegistry {
    enum Kind: String, Codable, CaseIterable { case bot, inbox }

    struct Tagged: Codable, Equatable { var value: String; var txId: String }

    struct Slot: Codable, Equatable {
        var current: String?
        var pending: Tagged?
        var releasing: Tagged?
        func holds(_ digest: String) -> Bool {
            current == digest || pending?.value == digest || releasing?.value == digest
        }
    }

    struct ActiveTx: Codable, Equatable {
        var txId: String
        var phase: String   // "reserving" | "cutover"
    }

    struct Record: Codable, Equatable {
        var name: String
        var generation: String
        var state: String          // "active" | "removing"
        var removingOp: String?
        var autostart: Bool
        var displayName: String
        var activeTx: [String: ActiveTx]
        var bot: Slot
        var inbox: Slot

        func slot(_ kind: Kind) -> Slot { kind == .bot ? bot : inbox }
        mutating func setSlot(_ kind: Kind, _ slot: Slot) {
            if kind == .bot { bot = slot } else { inbox = slot }
        }
    }

    struct Document: Codable, Equatable {
        var version: Int
        var records: [Record]
        func record(_ name: String) -> Record? { records.first { $0.name == name } }
        func index(_ name: String) -> Int? { records.firstIndex { $0.name == name } }
    }

    struct RegistryError: Error, CustomStringConvertible, Equatable {
        let description: String
        init(_ description: String) { self.description = description }
    }

    // MARK: - Paths

    struct Paths {
        var root: URL
        var registry: URL { root.appendingPathComponent("registry.json") }
        var lock: URL { root.appendingPathComponent("registry.lock") }
        var txDir: URL { root.appendingPathComponent("tx", isDirectory: true) }
        func txLease(_ txId: String) -> URL { txDir.appendingPathComponent("\(txId).lock") }

        static var live: Paths { Paths(root: MachinePaths.sharedRoot()) }
    }

    static let lockWaitSeconds: Double = 10
    static let maxBytes = 1024 * 1024

    enum Presence: Equatable {
        /// Definitely absent (ENOENT): a never-multi installation.
        case absent
        case present
        /// The lookup failed for another reason (permissions, a file where a
        /// directory should be, …): never treated as absent.
        case unreadable(String)
    }

    static func presence(_ paths: Paths = .live) -> Presence {
        var st = stat()
        if lstat(paths.registry.path, &st) == 0 { return .present }
        let err = errno
        if err == ENOENT { return .absent }
        return .unreadable(String(cString: strerror(err)))
    }

    /// True unless the registry is definitely absent (an unreadable registry
    /// counts as present: callers fail closed).
    static func exists(_ paths: Paths = .live) -> Bool {
        presence(paths) != .absent
    }

    // MARK: - Values

    /// Bot: the numeric bot id before `:` (a token rotation keeps the bot).
    /// Inbox: the trimmed, lower-cased address.
    static func normalize(_ kind: Kind, _ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .bot:
            let id = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            return (!id.isEmpty && id.allSatisfy { $0.isASCII && $0.isNumber }) ? id : nil
        case .inbox:
            let lower = trimmed.lowercased()
            return lower.contains("@") && lower.count >= 3 ? lower : nil
        }
    }

    static func digest(_ kind: Kind, _ raw: String) -> String? {
        guard let n = normalize(kind, raw) else { return nil }
        return SHA256.hash(data: Data("\(kind.rawValue):\(n)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Locked read-modify-write

    static func read(_ paths: Paths) throws -> Document? {
        var st = stat()
        guard lstat(paths.registry.path, &st) == 0 else {
            if errno == ENOENT { return nil }
            throw RegistryError("cannot read the assistants registry: \(String(cString: strerror(errno)))")
        }
        guard (st.st_mode & S_IFMT) == S_IFREG, st.st_size <= maxBytes else {
            throw RegistryError("the assistants registry is not a regular file or is too large — run `briglia doctor`")
        }
        let data = try Data(contentsOf: paths.registry)
        guard let doc = try? JSONDecoder().decode(Document.self, from: data), doc.version == 1 else {
            throw RegistryError("the assistants registry is damaged — run `briglia doctor`")
        }
        return doc
    }

    static func write(_ doc: Document, _ paths: Paths) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try PrivateStorage.writeAtomically(try encoder.encode(doc), to: paths.registry, mode: 0o600)
    }

    /// Run `body` under `registry.lock`; the document is written back only
    /// when `body` changed it. A missing registry is passed as nil and is
    /// created only if `body` sets one.
    static func withLock<T>(_ paths: Paths, _ body: (inout Document?) throws -> T) throws -> T {
        try PrivateStorage.ensureDirectory(paths.root, mode: 0o700)
        switch ProfileFileLock.take(paths.lock, waitSeconds: lockWaitSeconds) {
        case .busy:
            throw RegistryError("the assistants registry is busy — try again in a moment")
        case .failed(let why):
            throw RegistryError(why)
        case .acquired(let lock):
            defer { lock.release() }
            var doc = try read(paths)
            let before = doc
            let result = try body(&doc)
            if let doc, doc != before { try write(doc, paths) }
            return result
        }
    }

    // MARK: - Dead-writer cleanup

    /// Clear every transaction entry of `record` whose writer lease is dead.
    /// Never touches an entry whose txId differs from the dead transaction's.
    static func cleanupDeadWriters(_ record: inout Record, _ paths: Paths) {
        for kind in Kind.allCases {
            guard let active = record.activeTx[kind.rawValue] else { continue }
            guard ProfileFileLock.probe(paths.txLease(active.txId)) == .dead else { continue }
            var slot = record.slot(kind)
            if slot.pending?.txId == active.txId { slot.pending = nil }
            if slot.releasing?.txId == active.txId { slot.releasing = nil }
            record.setSlot(kind, slot)
            record.activeTx[kind.rawValue] = nil
            try? FileManager.default.removeItem(at: paths.txLease(active.txId))
        }
        // Other settings transactions (e.g. the ChatGPT scope change): only
        // the entry itself, when its writer lease is dead.
        for (key, active) in record.activeTx where Kind(rawValue: key) == nil {
            if ProfileFileLock.probe(paths.txLease(active.txId)) == .dead {
                record.activeTx[key] = nil
                try? FileManager.default.removeItem(at: paths.txLease(active.txId))
            }
        }
        // Orphans: entries without an activeTx whose writer is dead.
        for kind in Kind.allCases where record.activeTx[kind.rawValue] == nil {
            var slot = record.slot(kind)
            if let p = slot.pending, ProfileFileLock.probe(paths.txLease(p.txId)) == .dead { slot.pending = nil }
            if let r = slot.releasing, ProfileFileLock.probe(paths.txLease(r.txId)) == .dead { slot.releasing = nil }
            record.setSlot(kind, slot)
        }
    }

    /// Which OTHER assistant holds `digest` (current, pending or releasing),
    /// after dead writers were cleaned.
    static func holder(of digest: String, kind: Kind, excluding name: String, in doc: Document) -> Record? {
        doc.records.first { $0.name != name && $0.slot(kind).holds(digest) }
    }

    static func cleanAll(_ doc: inout Document, _ paths: Paths) {
        for i in doc.records.indices { cleanupDeadWriters(&doc.records[i], paths) }
    }

    static func conflictMessage(_ kind: Kind, owner: Record) -> String {
        switch kind {
        case .bot:
            return "This Telegram bot is already used by the assistant ‘\(owner.displayName)’. Each assistant needs its own bot (BotFather → /newbot)."
        case .inbox:
            return "This email inbox is already used by the assistant ‘\(owner.displayName)’. Each assistant needs its own inbox."
        }
    }

    // MARK: - Transactions (§5.6 steps 1–6)

    final class Transaction {
        let paths: Paths
        let profile: String
        let kind: Kind
        /// nil = a removal (the value is cleared at commit).
        let digest: String?
        let txId: String
        private var lease: ProfileFileLock?
        private(set) var committed = false

        fileprivate init(paths: Paths, profile: String, kind: Kind, digest: String?, txId: String, lease: ProfileFileLock) {
            self.paths = paths; self.profile = profile; self.kind = kind
            self.digest = digest; self.txId = txId; self.lease = lease
        }

        /// Step 4: under registry.lock (then secrets.lock inside
        /// `writeSecret`), verify ownership, write the secret, move the old
        /// value to `releasing` and `pending` to `current`. No network.
        func commit(writeSecret: () throws -> Void) throws {
            try AssistantRegistry.withLock(paths) { doc in
                guard var d = doc, let i = d.index(profile) else {
                    throw RegistryError("this assistant is no longer registered")
                }
                var record = d.records[i]
                var slot = record.slot(kind)
                if let digest {
                    guard record.activeTx[kind.rawValue]?.txId == txId, slot.pending?.txId == txId,
                          slot.pending?.value == digest else {
                        throw RegistryError("the reservation for this change was lost — nothing was changed; try again")
                    }
                } else {
                    guard record.activeTx[kind.rawValue]?.txId == txId else {
                        throw RegistryError("the reservation for this change was lost — nothing was changed; try again")
                    }
                }
                try writeSecret()
                // The old value stays protected (`releasing`) until its
                // consumer is quiescent (step 6), for removals too.
                if let old = slot.current, old != digest { slot.releasing = Tagged(value: old, txId: txId) }
                slot.current = digest
                slot.pending = nil
                record.setSlot(kind, slot)
                record.activeTx[kind.rawValue] = ActiveTx(txId: txId, phase: "cutover")
                d.records[i] = record
                doc = d
            }
            committed = true
        }

        /// Step 6: after the old consumer is quiescent, clear `releasing` and
        /// `activeTx` (only when they still carry this txId) and release the
        /// writer lease.
        func finish() throws {
            defer { releaseLease() }
            try AssistantRegistry.withLock(paths) { doc in
                guard var d = doc, let i = d.index(profile) else { return }
                var record = d.records[i]
                var slot = record.slot(kind)
                if slot.releasing?.txId == txId { slot.releasing = nil }
                if slot.pending?.txId == txId { slot.pending = nil }
                record.setSlot(kind, slot)
                if record.activeTx[kind.rawValue]?.txId == txId { record.activeTx[kind.rawValue] = nil }
                d.records[i] = record
                doc = d
            }
        }

        /// Abort before commit: remove our pending/activeTx only.
        func abort() {
            defer { releaseLease() }
            guard !committed else { try? finish(); return }
            _ = try? AssistantRegistry.withLock(paths) { doc in
                guard var d = doc, let i = d.index(profile) else { return }
                var record = d.records[i]
                var slot = record.slot(kind)
                if slot.pending?.txId == txId { slot.pending = nil }
                record.setSlot(kind, slot)
                if record.activeTx[kind.rawValue]?.txId == txId { record.activeTx[kind.rawValue] = nil }
                d.records[i] = record
                doc = d
            }
        }

        private func releaseLease() {
            lease?.release()
            lease = nil
            try? FileManager.default.removeItem(at: paths.txLease(txId))
            MemberEntry.forgetOwnTx(txId)
        }

        var isOpen: Bool { lease != nil }

        deinit { lease?.release() }
    }

    /// Steps 1–2: create and hold the writer lease, then under the lock
    /// refuse an unfinished live change of the same kind or a value held by
    /// another assistant, else publish `activeTx` and `pending`. Must be
    /// called before ANY network use of the new identity.
    static func begin(profile: String, kind: Kind, rawValue: String?, paths: Paths = .live,
                      precheck: (Record) -> String? = { _ in nil }) throws -> Transaction {
        // nil/empty = a removal: published like any change (startup waits
        // for it, overlapping changes are refused), committed by clearing.
        let removal = (rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
        let digest: String? = removal ? nil : self.digest(kind, rawValue ?? "")
        if !removal, digest == nil {
            throw RegistryError(kind == .bot ? "that does not look like a Telegram bot token" : "that does not look like an email address")
        }
        try PrivateStorage.ensureDirectory(paths.root, mode: 0o700)
        try PrivateStorage.ensureDirectory(paths.txDir, mode: 0o700)
        let txId = UUID().uuidString.lowercased()
        guard case .acquired(let lease) = ProfileFileLock.take(paths.txLease(txId)) else {
            throw RegistryError("could not create the change lease for this assistant")
        }
        do {
            try withLock(paths) { doc in
                guard var d = doc, let i = d.index(profile) else {
                    throw RegistryError("this assistant is not registered on this computer")
                }
                cleanAll(&d, paths)
                if d.records[i].state != "active" {
                    throw RegistryError("this assistant is being removed")
                }
                // The offline-setter rule (§5.6): probed in the SAME critical
                // section that publishes activeTx, so a starting assistant
                // either is seen here or sees our activeTx under this lock.
                if let refusal = precheck(d.records[i]) { throw RegistryError(refusal) }
                if let active = d.records[i].activeTx[kind.rawValue] {
                    _ = active
                    throw RegistryError(kind == .bot
                        ? "another change of this assistant's bot is still finishing — try again in a moment"
                        : "another change of this assistant's inbox is still finishing — try again in a moment")
                }
                if let digest, let owner = holder(of: digest, kind: kind, excluding: profile, in: d) {
                    throw RegistryError(conflictMessage(kind, owner: owner))
                }
                if let digest {
                    var slot = d.records[i].slot(kind)
                    slot.pending = Tagged(value: digest, txId: txId)
                    d.records[i].setSlot(kind, slot)
                }
                d.records[i].activeTx[kind.rawValue] = ActiveTx(txId: txId, phase: "reserving")
                doc = d
            }
        } catch {
            lease.release()
            try? FileManager.default.removeItem(at: paths.txLease(txId))
            throw error
        }
        MemberEntry.noteOwnTx(txId)
        return Transaction(paths: paths, profile: profile, kind: kind, digest: digest, txId: txId, lease: lease)
    }

    // MARK: - Settings transactions (startup exclusion for other settings)

    /// A writer lease published as `activeTx[key]` in one registry critical
    /// section with `precheck` (the offline-setter probe), so a starting
    /// assistant waits for it exactly like for a bot/inbox change (§5.6).
    final class SettingsTransaction {
        let paths: Paths, profile: String, key: String, txId: String
        private var lease: ProfileFileLock?
        fileprivate init(paths: Paths, profile: String, key: String, txId: String, lease: ProfileFileLock) {
            self.paths = paths; self.profile = profile; self.key = key; self.txId = txId; self.lease = lease
        }
        func finish() {
            _ = try? AssistantRegistry.withLock(paths) { doc in
                guard var d = doc, let i = d.index(profile), d.records[i].activeTx[key]?.txId == txId else { return }
                d.records[i].activeTx[key] = nil
                doc = d
            }
            lease?.release(); lease = nil
            try? FileManager.default.removeItem(at: paths.txLease(txId))
            MemberEntry.forgetOwnTx(txId)
        }
        deinit { if lease != nil { finish() } }
    }

    static func beginSettings(profile: String, key: String, paths: Paths = .live,
                              precheck: (Record) -> String? = { _ in nil }) throws -> SettingsTransaction {
        try PrivateStorage.ensureDirectory(paths.txDir, mode: 0o700)
        let txId = UUID().uuidString.lowercased()
        guard case .acquired(let lease) = ProfileFileLock.take(paths.txLease(txId)) else {
            throw RegistryError("could not create the change lease for this assistant")
        }
        do {
            try withLock(paths) { doc in
                guard var d = doc, let i = d.index(profile) else { throw RegistryError("this assistant is not registered on this computer") }
                cleanAll(&d, paths)
                if d.records[i].state != "active" { throw RegistryError("this assistant is being removed") }
                if let refusal = precheck(d.records[i]) { throw RegistryError(refusal) }
                if d.records[i].activeTx[key] != nil { throw RegistryError("another change of this setting is still finishing — try again in a moment") }
                d.records[i].activeTx[key] = ActiveTx(txId: txId, phase: "changing")
                doc = d
            }
        } catch {
            lease.release()
            try? FileManager.default.removeItem(at: paths.txLease(txId))
            throw error
        }
        MemberEntry.noteOwnTx(txId)
        return SettingsTransaction(paths: paths, profile: profile, key: key, txId: txId, lease: lease)
    }

    // MARK: - Startup reconciliation

    enum ReconcileResult: Equatable {
        /// No registry: today's behaviour.
        case noRegistry
        case allowed
        /// Another assistant holds the value (message explains).
        case conflict(String)
        /// A live change of this assistant's own identity is finishing.
        case busy(String)
        /// The caller's read step found the persisted setting changed since
        /// the caller captured it: nothing was adopted, released or written
        /// (Codex stage-1 R5 — a failed consistency check is never a release).
        case changed
    }

    /// The value read inside the registry lock: the configured identity
    /// (empty = nothing configured), or an abort that leaves the slot alone.
    enum ReconcileRead: Equatable {
        case configured(String)
        case aborted
    }

    static func reconcile(profile: String, kind: Kind, read: () -> String?, paths: Paths = .live) -> ReconcileResult {
        reconcile(profile: profile, kind: kind, readChecked: { .configured(read() ?? "") }, paths: paths)
    }

    /// Before any poll or discovery: compare the profile's persisted value
    /// (read inside the lock) with its record. A value not in the record is
    /// adopted as `current` when free; a conflict refuses the channel.
    static func reconcile(profile: String, kind: Kind, readChecked: () -> ReconcileRead, paths: Paths = .live) -> ReconcileResult {
        switch presence(paths) {
        case .absent:
            // Only default can be a never-multi installation; an extra
            // without its registry was registered once and must not run
            // unreserved (fail closed).
            return profile == AssistantProfile.defaultName
                ? .noRegistry
                : .conflict("this assistant's registry is missing; run `briglia doctor`")
        case .unreadable(let why):
            return .conflict("the assistants registry cannot be read (\(why)); run `briglia doctor`")
        case .present:
            break
        }
        do {
            return try withLock(paths) { doc -> ReconcileResult in
                guard var d = doc else {
                    return profile == AssistantProfile.defaultName
                        ? .noRegistry
                        : .conflict("this assistant's registry is missing; run `briglia doctor`")
                }
                // Read first, before any change to the document: an aborted
                // read returns with `doc` untouched, so nothing is written.
                guard case .configured(let configured) = readChecked() else { return .changed }
                cleanAll(&d, paths)
                if d.index(profile) == nil {
                    guard profile == AssistantProfile.defaultName else {
                        doc = d
                        return .conflict("this assistant is not registered on this computer")
                    }
                    d.records.append(newRecord(name: profile, displayName: "Bree"))
                }
                let i = d.index(profile)!
                let raw = configured.trimmingCharacters(in: .whitespacesAndNewlines)
                var slot = d.records[i].slot(kind)
                if raw.isEmpty {
                    // Nothing configured: free what this record claimed.
                    if d.records[i].activeTx[kind.rawValue] == nil { slot.current = nil }
                    d.records[i].setSlot(kind, slot)
                    doc = d
                    return .allowed
                }
                guard let digest = digest(kind, raw) else {
                    doc = d
                    return .allowed   // malformed values never poll anyway
                }
                if slot.current == digest { doc = d; return .allowed }
                if let owner = holder(of: digest, kind: kind, excluding: profile, in: d) {
                    doc = d
                    return .conflict(conflictMessage(kind, owner: owner))
                }
                if let active = d.records[i].activeTx[kind.rawValue], slot.pending?.value == digest,
                   ProfileFileLock.probe(paths.txLease(active.txId)) != .dead {
                    doc = d
                    return .busy("a settings change for this assistant is finishing; starting in a moment")
                }
                slot.current = digest
                if slot.pending?.value == digest { slot.pending = nil }
                d.records[i].setSlot(kind, slot)
                doc = d
                return .allowed
            }
        } catch {
            // An unreadable registry fails closed: the channel is not polled.
            return .conflict("the assistants registry cannot be read (\(error)); run `briglia doctor`")
        }
    }

    // MARK: - Discovery and inbox scope

    /// May this profile run Telegram discovery (`getUpdates`, which competes
    /// with the bot's poller) on `token`? nil = yes. Never-multi installs are
    /// unchanged; with a registry only the bot this profile already holds as
    /// `current` may be scanned. Changing to a NEW bot in multi mode waits for
    /// the reservation-wired setters of a later stage (refused, fail closed).
    static func telegramDiscoveryRefusal(profile: String = AssistantProfile.selectedName, token: String,
                                         paths: Paths = .live) -> String? {
        switch presence(paths) {
        case .absent:
            return profile == AssistantProfile.defaultName ? nil : "this assistant's registry is missing; run `briglia doctor`"
        case .unreadable(let why):
            return "the assistants registry cannot be read (\(why)); run `briglia doctor`"
        case .present:
            break
        }
        guard let digest = digest(.bot, token) else { return "That doesn't look like a bot token." }
        do {
            return try withLock(paths) { doc -> String? in
                guard var d = doc else { return "the assistants registry cannot be read; run `briglia doctor`" }
                cleanAll(&d, paths)
                doc = d
                if let owner = holder(of: digest, kind: .bot, excluding: profile, in: d) {
                    return conflictMessage(.bot, owner: owner)
                }
                if d.record(profile)?.bot.current == digest { return nil }
                // A new bot may be scanned only under this profile's own live
                // reservation (§5.6 step 2: reserve before discovery).
                if let record = d.record(profile), let pending = record.bot.pending, pending.value == digest,
                   record.activeTx[Kind.bot.rawValue]?.txId == pending.txId,
                   ProfileFileLock.probe(paths.txLease(pending.txId)) == .live {
                    return nil
                }
                return "Reserve this bot for the assistant first (start the change again with /switchbot <token>)."
            }
        } catch {
            return "the assistants registry cannot be read (\(error)); run `briglia doctor`"
        }
    }

    enum InboxScope: Equatable {
        /// Never-multi: every inbox the key returns (today's behaviour).
        case all
        /// Only the inbox with this digest (the profile's reservation).
        case only(String)
        /// Nothing may be read.
        case none(String)
    }

    /// Which AgentMail inboxes this profile may read: enforced at the
    /// service boundary for polling AND prompt snapshots (plan D9).
    static func inboxScope(profile: String = AssistantProfile.selectedName, configuredInbox: String?,
                           paths: Paths = .live) -> InboxScope {
        if case .absent = presence(paths), profile == AssistantProfile.defaultName { return .all }
        let inbox = configuredInbox?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !inbox.isEmpty, let digest = digest(.inbox, inbox) else {
            return .none("no inbox is configured for this assistant")
        }
        switch reconcile(profile: profile, kind: .inbox, read: { inbox }, paths: paths) {
        case .noRegistry, .allowed: return .only(digest)
        case .conflict(let m), .busy(let m): return .none(m)
        case .changed: return .none("the inbox setting changed; reading resumes at the next check")
        }
    }

    // MARK: - Records

    static func newRecord(name: String, displayName: String) -> Record {
        Record(name: name, generation: UUID().uuidString.lowercased(), state: "active", removingOp: nil,
               autostart: true, displayName: displayName, activeTx: [:], bot: Slot(), inbox: Slot())
    }

    static func displayNameTaken(_ displayName: String, in doc: Document, excluding name: String? = nil) -> Bool {
        let wanted = displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return doc.records.contains { $0.name != name && $0.displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == wanted }
    }
}
