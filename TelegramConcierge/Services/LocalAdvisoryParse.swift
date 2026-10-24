import Foundation

/// Strict structural parse of the advisory-list payload (§9.5.3). A
/// structural problem (wrong type, a bound exceeded, a malformed ID, a
/// duplicate identity entry) rejects the whole document: every state is then
/// unknown. Values the format allows to grow later are tolerated narrowly:
/// an unknown coverage status is "not ok"; an unknown range type, event or
/// version scheme makes only that advisory unknown; unknown keys are ignored
/// (additive fields, e.g. the support floor of §9.5.8, must not break older
/// clients). Nothing here is ever executed or rendered as text.
extension LocalAdvisory {
    static func parseDocument(_ payload: Data) throws -> Document {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: payload),
              case .object(let o) = root else { throw Invalid(reason: "payload is not a JSON object") }
        guard case .int(let schema)? = o["schema"], schema == schemaVersion else { throw Invalid(reason: "unsupported schema") }
        let sequence = try int(o["sequence"], "sequence")
        let published = try date(o["published"], "published")
        let expires = try date(o["expires"], "expires")

        var declared: [String: [String]] = [:]
        for item in try array(o["declared"], "declared", max: maxDeclaredEcosystems) {
            guard case .object(let d) = item else { throw Invalid(reason: "declared entry is not an object") }
            let eco = try name(d["ecosystem"], "declared.ecosystem")
            guard declared[eco] == nil else { throw Invalid(reason: "ecosystem declared twice") }
            let sources = try array(d["sources"], "declared.sources", max: maxSourcesPerEcosystem).map { try name($0, "source") }
            guard !sources.isEmpty, Set(sources).count == sources.count else { throw Invalid(reason: "declared sources empty or repeated") }
            declared[eco] = sources
        }

        var coverage: [CoverageRow] = []
        for item in try array(o["coverage"], "coverage", max: maxCoverageRows) {
            guard case .object(let c) = item else { throw Invalid(reason: "coverage row is not an object") }
            let status: CoverageStatus?
            guard case .string(let raw)? = c["status"], raw.utf8.count <= 32 else { throw Invalid(reason: "coverage status missing") }
            status = CoverageStatus(rawValue: raw)
            coverage.append(CoverageRow(identity: try string(c["identity"], "coverage.identity"),
                                        source: try name(c["source"], "coverage.source"),
                                        status: status, checkedAt: try date(c["checkedAt"], "coverage.checkedAt")))
        }

        var entries: [Entry] = []
        var seen = Set<String>()
        for item in try array(o["entries"], "entries", max: maxIdentities) {
            let entry = try parseEntry(item)
            guard seen.insert(entry.identity.key).inserted else { throw Invalid(reason: "two entries for one identity") }
            entries.append(entry)
        }
        return Document(schema: schema, sequence: sequence, published: published, expires: expires,
                        declared: declared, coverage: coverage, entries: entries)
    }

    static func parseEntry(_ raw: JSONValue) throws -> Entry {
        guard case .object(let e) = raw else { throw Invalid(reason: "entry is not an object") }
        let identity = try parseIdentity(e["identity"])
        guard case .string(let scheme)? = e["scheme"], scheme.utf8.count <= 32 else { throw Invalid(reason: "entry scheme missing") }
        let advisories = try array(e["advisories"], "advisories", max: maxAdvisoriesPerIdentity).map(parseAdvisory)
        return Entry(identity: identity, scheme: scheme, advisories: advisories)
    }

    static func parseIdentity(_ raw: JSONValue?) throws -> Identity {
        guard case .object(let i)? = raw, case .string(let k)? = i["kind"], let kind = IdentityKind(rawValue: k) else {
            throw Invalid(reason: "identity kind missing or unknown")
        }
        var id = Identity(kind: kind)
        func need(_ f: String) throws -> String { try name(i[f], "identity.\(f)") }
        switch kind {
        case .deb:
            id.distro = try need("distro"); id.release = try need("release"); id.source = try need("source")
            guard ["debian", "ubuntu"].contains(id.distro!) else { throw Invalid(reason: "deb distro not debian|ubuntu") }
        case .brew:
            id.tap = try need("tap"); id.formula = try need("formula")
            guard case .int(let vs)? = i["versionScheme"], vs >= 0, vs < 1000 else { throw Invalid(reason: "brew versionScheme missing") }
            id.versionScheme = vs
        case .cask:
            id.token = try need("token")
        case .vendor:
            id.vendor = try need("vendor"); id.product = try need("product")
            id.platform = try need("platform"); id.flavour = try need("flavour")
        }
        return id
    }

    static func parseAdvisory(_ raw: JSONValue) throws -> Advisory {
        guard case .object(let a) = raw else { throw Invalid(reason: "advisory is not an object") }
        var ids: [String] = []
        for v in try array(a["ids"], "ids", max: maxIdsPerAdvisory) {
            guard case .string(let s) = v, s.range(of: idPattern, options: .regularExpression) != nil else {
                throw Invalid(reason: "advisory ID does not match the ID pattern")
            }
            let u = s.uppercased()
            if !ids.contains(u) { ids.append(u) }
        }
        guard !ids.isEmpty else { throw Invalid(reason: "advisory without IDs") }
        guard case .string(let sev)? = a["severity"], let severity = ReleaseSecurity.Level(rawValue: sev) else {
            throw Invalid(reason: "severity is not recommended|critical")
        }
        guard case .bool(let kev)? = a["kev"] else { throw Invalid(reason: "kev is not a bool") }
        var kevAdded: String? = nil
        if let v = a["kevAdded"], !v.isNullValue { kevAdded = try string(v, "kevAdded") }
        let affected = try parseAffected(a["affected"])
        var remediation: Remediation? = nil
        if let r = a["remediation"], !r.isNullValue { remediation = try parseRemediation(r) }
        var reason: NoFixReason? = nil
        if let r = a["noFixReason"], !r.isNullValue {
            guard case .string(let s) = r else { throw Invalid(reason: "noFixReason is not a string") }
            reason = NoFixReason(rawValue: s) ?? .unknown
        }
        var binaries: [String]? = nil
        if let b = a["binaries"], !b.isNullValue {
            binaries = try array(b, "binaries", max: maxBinaries).map { try name($0, "binary") }
        }
        var withdrawn = false
        if let w = a["withdrawn"] {
            guard case .bool(let flag) = w else { throw Invalid(reason: "withdrawn is not a bool") }
            withdrawn = flag
        }
        return Advisory(ids: ids, severity: severity, kev: kev, kevAdded: kevAdded, affected: affected,
                        remediation: remediation, noFixReason: reason, binaries: binaries, withdrawn: withdrawn)
    }

    static func parseAffected(_ raw: JSONValue?) throws -> Affected {
        switch raw {
        case .string("unknown")?:
            return .unknown
        case .object(let o)?:
            if let r = o["ranges"] {
                return .ranges(try array(r, "ranges", max: maxRangesPerAdvisory).map(parseRange))
            }
            if let v = o["versions"] {
                return .versions(try array(v, "versions", max: maxVersionsPerAdvisory).map { try string($0, "version") })
            }
            throw Invalid(reason: "affected has neither ranges nor versions")
        default:
            throw Invalid(reason: "affected missing")
        }
    }

    static func parseRange(_ raw: JSONValue) throws -> Range {
        guard case .object(let r) = raw else { throw Invalid(reason: "range is not an object") }
        guard case .string(let type)? = r["type"], type.utf8.count <= 32 else { throw Invalid(reason: "range type missing") }
        var unsupported = !["ECOSYSTEM", "SEMVER"].contains(type)
        var events: [Event] = []
        for item in try array(r["events"], "events", max: maxEventsPerRange) {
            guard case .object(let e) = item, e.count == 1, let (k, v) = e.first else {
                throw Invalid(reason: "an event must have exactly one key")
            }
            let version = try string(v, "event version")
            guard !version.isEmpty else { throw Invalid(reason: "empty event version") }
            if let kind = EventKind(rawValue: k) {
                events.append(Event(kind: kind, version: version))
            } else {
                unsupported = true
            }
        }
        if events.isEmpty { unsupported = true }
        return Range(type: type, events: events, unsupported: unsupported)
    }

    static func parseRemediation(_ raw: JSONValue) throws -> Remediation {
        guard case .object(let r) = raw else { throw Invalid(reason: "remediation is not an object") }
        var fixed: [FixedVersion] = []
        for item in try array(r["fixed"], "remediation.fixed", max: maxFixedLines) {
            guard case .object(let f) = item else { throw Invalid(reason: "fixed entry is not an object") }
            var line: String? = nil
            if let l = f["line"], !l.isNullValue { line = try string(l, "fixed.line") }
            let v = try string(f["version"], "fixed.version")
            guard !v.isEmpty else { throw Invalid(reason: "empty fixed version") }
            fixed.append(FixedVersion(line: line, version: v))
        }
        guard !fixed.isEmpty else { throw Invalid(reason: "remediation without a fixed version") }
        var pocket: Pocket? = nil
        if let p = r["pocket"], !p.isNullValue {
            guard case .string(let s) = p, let parsed = Pocket(rawValue: s) else { throw Invalid(reason: "unknown pocket") }
            pocket = parsed
        }
        return Remediation(fixed: fixed, pocket: pocket)
    }

    // MARK: - Field helpers

    private static func array(_ v: JSONValue?, _ field: String, max: Int) throws -> [JSONValue] {
        guard case .array(let items)? = v else { throw Invalid(reason: "\(field) is not a list") }
        guard items.count <= max else { throw Invalid(reason: "\(field) has more than \(max) entries") }
        return items
    }

    private static func string(_ v: JSONValue?, _ field: String) throws -> String {
        guard case .string(let s)? = v else { throw Invalid(reason: "\(field) is not a string") }
        guard s.utf8.count <= maxStringBytes else { throw Invalid(reason: "\(field) is longer than \(maxStringBytes) bytes") }
        guard !s.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw Invalid(reason: "\(field) contains control characters")
        }
        return s
    }

    private static func name(_ v: JSONValue?, _ field: String) throws -> String {
        let s = try string(v, field)
        guard s.range(of: namePattern, options: .regularExpression) != nil else { throw Invalid(reason: "\(field) is not a valid name") }
        return s
    }

    private static func int(_ v: JSONValue?, _ field: String) throws -> Int {
        guard case .int(let n)? = v, n >= 0, n < maxSequence else { throw Invalid(reason: "\(field) is not an integer in [0, 2^53)") }
        return n
    }

    static func date(_ v: JSONValue?, _ field: String) throws -> Date {
        guard case .string(let s)? = v, s.utf8.count <= 40 else { throw Invalid(reason: "\(field) is not a timestamp") }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        guard let d = f.date(from: s) else { throw Invalid(reason: "\(field) is not an ISO 8601 timestamp") }
        return d
    }
}

private extension JSONValue {
    var isNullValue: Bool { if case .null = self { return true }; return false }
}
