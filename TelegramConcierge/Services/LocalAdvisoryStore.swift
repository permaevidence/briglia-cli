import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Durable files of the local-tools check (security plan v16 §9.5.3, §9.5.5):
/// - `~/.local/share/briglia/update/advisory-list.json`: the highest-observed
///   advisory list per trust domain (separate from `notice.json`,
///   `ReleaseTrustStore` and any install trust floor) plus fetch cadence;
/// - `~/.local/share/briglia/update/localvuln.json`: the send-once table, its
///   single attempt record and the last evaluation shown by /status, doctor
///   and the menu.
/// Both are written only under the shared `update-check.lock` (ordered with
/// the shared notice generation in `update-check.json`) and atomically.
enum LocalAdvisoryStore {
    static let maxDomains = 4
    /// Owner decision L1 (2026-10-24): each domain record holds one verified
    /// payload (≤ 2 MiB) as base64 (written without slash escaping) plus
    /// small fields, which is under the envelope cap; `maxDomains` of them
    /// plus the cadence fields. (The old 1 MiB value could not hold four
    /// 256 KiB payloads either.)
    static let maxObservationBytes = maxDomains * LocalAdvisory.maxEnvelopeBytes + 64 * 1024
    /// The send-once rows (≤ 256), one attempt and the last evaluation: up
    /// to one report per watched tool, each with up to 512 matched advisories
    /// of ≤ 16 IDs (`LocalTools.maxReportIds`). The selftest checks a
    /// maximal report for every watched tool fits; above it the write is
    /// refused and the check shows "cannot be saved" (nothing sent).
    static let maxLocalVulnBytes = 16 * 1024 * 1024

    struct Paths {
        var notice: UpdateNoticeStore.Paths
        var observation: URL
        var localvuln: URL

        static var live: Paths {
            let n = UpdateNoticeStore.Paths.live
            let dir = n.state.deletingLastPathComponent()
            return Paths(notice: n, observation: dir.appendingPathComponent("advisory-list.json"),
                         localvuln: dir.appendingPathComponent("localvuln.json"))
        }

        static func under(_ notice: UpdateNoticeStore.Paths) -> Paths {
            let dir = notice.state.deletingLastPathComponent()
            return Paths(notice: notice, observation: dir.appendingPathComponent("advisory-list.json"),
                         localvuln: dir.appendingPathComponent("localvuln.json"))
        }
    }

    // MARK: - Observation model (§9.5.3 "Client verification")

    struct DomainRecord: Codable, Equatable {
        var domain: String
        var sequence: Int
        var contentId: String
        var published: Date
        var expires: Date
        /// The exact verified payload (re-parsed on read; never re-trusted
        /// without its recorded content identity).
        var payload: Data
        var firstSeenAt: Date
        var lastConfirmedAt: Date
        var conflictSince: Date?
        var lowerSince: Date?
        var lastLowerSequence: Int?
        var touchedAt: Date
    }

    struct ObservationState: Codable, Equatable {
        var schema = 1
        var lastAttempt: Date?
        var lastSuccess: Date?
        var lastProblem: String?
        var domains: [DomainRecord] = []

        func domain(_ id: String) -> DomainRecord? { domains.first { $0.domain == id } }
    }

    enum ObservationEffect: Equatable { case first, newer, renewal, conflict, lower }

    /// The §5.2-style update rules for the advisory list: a lower sequence is
    /// ignored (never regresses state); same sequence + same bytes confirms;
    /// same sequence + other bytes is a conflict (the earlier document is
    /// kept, messages stop until a higher sequence arrives); higher replaces.
    @discardableResult
    static func observe(_ s: inout ObservationState, _ v: LocalAdvisory.Verified, domain: String, now: Date) -> ObservationEffect {
        s.lastSuccess = now
        s.lastProblem = nil
        let fresh = DomainRecord(domain: domain, sequence: v.document.sequence, contentId: v.contentId,
                                 published: v.document.published, expires: v.document.expires, payload: v.payload,
                                 firstSeenAt: now, lastConfirmedAt: now, conflictSince: nil, lowerSince: nil,
                                 lastLowerSequence: nil, touchedAt: now)
        guard let i = s.domains.firstIndex(where: { $0.domain == domain }) else {
            s.domains.append(fresh)
            while s.domains.count > maxDomains,
                  let victim = s.domains.enumerated().filter({ $0.element.domain != domain }).min(by: { $0.element.touchedAt < $1.element.touchedAt }) {
                s.domains.remove(at: victim.offset)
            }
            return .first
        }
        var d = s.domains[i]
        let effect: ObservationEffect
        if v.document.sequence > d.sequence {
            d = fresh
            effect = .newer
        } else if v.document.sequence == d.sequence, v.contentId == d.contentId {
            d.lastConfirmedAt = now
            d.lowerSince = nil
            effect = .renewal
        } else if v.document.sequence == d.sequence {
            if d.conflictSince == nil { d.conflictSince = now }
            effect = .conflict
        } else {
            if d.lowerSince == nil { d.lowerSince = now }
            d.lastLowerSequence = v.document.sequence
            effect = .lower
        }
        d.touchedAt = now
        s.domains[i] = d
        return effect
    }

    enum ListView: Equatable {
        case none(String)
        case expired(DomainRecord)
        case current(LocalAdvisory.Document, DomainRecord)
    }

    /// The document to match with, re-parsed from the stored bytes.
    static func view(_ s: ObservationState, domain: String, now: Date) -> ListView {
        guard let d = s.domain(domain) else { return .none("no advisory list has been received yet") }
        guard d.expires > now else { return .expired(d) }
        guard let doc = try? LocalAdvisory.parseDocument(d.payload), doc.sequence == d.sequence else {
            return .none("the stored advisory list cannot be read")
        }
        return .current(doc, d)
    }

    // MARK: - Coding / files

    static func encoder() -> JSONEncoder {
        let e = UpdateNoticeStore.encoder()
        e.outputFormatting.insert(.withoutEscapingSlashes)   // base64 payloads: no "\/" growth
        return e
    }
    static func decoder() -> JSONDecoder { UpdateNoticeStore.decoder() }

    static func read<T: Decodable>(_ type: T.Type, at url: URL, maxBytes: Int, quarantine: Bool, now: Date) -> T? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        if Int(st.st_size) <= maxBytes, (st.st_mode & S_IFMT) == S_IFREG,
           let data = FileManager.default.contents(atPath: url.path), let v = try? decoder().decode(T.self, from: data) {
            return v
        }
        if quarantine {
            let aside = url.deletingLastPathComponent()
                .appendingPathComponent(url.lastPathComponent + ".corrupt-\(Int(now.timeIntervalSince1970))")
            _ = rename(url.path, aside.path)
        }
        return nil
    }

    /// Selftest seam: every write fails.
    nonisolated(unsafe) static var failWritesForTesting = false

    static func write<T: Encodable>(_ value: T, to url: URL, maxBytes: Int) throws {
        if failWritesForTesting { throw UpdateNoticeStore.StoreError(message: "injected write failure") }
        let data = try encoder().encode(value)
        guard data.count <= maxBytes else {
            throw UpdateNoticeStore.StoreError(message: "\(url.lastPathComponent) would be \(data.count) bytes (limit \(maxBytes)) — refusing to write")
        }
        try PrivateStorage.ensureDirectoryScoped(url.deletingLastPathComponent())
        try PrivateStorage.writeAtomically(data, to: url)
    }

    /// Lock → setting + both states → body → atomic writes of what changed.
    static func transaction<R>(_ p: Paths, now: Date,
                               _ body: (UpdateNoticeStore.SettingRead, inout ObservationState, inout LocalVulnState) throws -> R) throws -> R {
        try UpdateNoticeStore.withLock(p.notice) {
            let setting = UpdateNoticeStore.readSetting(p.notice)
            var obs = read(ObservationState.self, at: p.observation, maxBytes: maxObservationBytes, quarantine: true, now: now) ?? ObservationState()
            var vuln = read(LocalVulnState.self, at: p.localvuln, maxBytes: maxLocalVulnBytes, quarantine: true, now: now) ?? LocalVulnState()
            if obs.schema != 1 { obs = ObservationState() }
            if vuln.schema != 1 { vuln = LocalVulnState() }
            let (obs0, vuln0) = (obs, vuln)
            let result = try body(setting, &obs, &vuln)
            if obs != obs0 { try write(obs, to: p.observation, maxBytes: maxObservationBytes) }
            if vuln != vuln0 { try write(vuln, to: p.localvuln, maxBytes: maxLocalVulnBytes) }
            return result
        }
    }

    /// Lockless read for doctor, the menu and /status.
    static func snapshot(_ p: Paths = .live) -> (ObservationState?, LocalVulnState?) {
        let now = Date()
        return (read(ObservationState.self, at: p.observation, maxBytes: maxObservationBytes, quarantine: false, now: now),
                read(LocalVulnState.self, at: p.localvuln, maxBytes: maxLocalVulnBytes, quarantine: false, now: now))
    }

    /// `/deleteuserdata` part (called by `UpdateNoticeStore.wipeDerivedState`
    /// while it holds the lock and after it bumped the generation).
    static func unlinkDerived(_ p: Paths) throws {
        // v17 §9.5.9: the macOS weekly-updates state goes with them.
        for url in [p.observation, p.localvuln, MacUpdatesStore.url(p.notice)] where unlink(url.path) != 0 && errno != ENOENT {
            throw UpdateNoticeStore.StoreError(message: "could not delete \(url.path): \(String(cString: strerror(errno)))")
        }
    }
}
