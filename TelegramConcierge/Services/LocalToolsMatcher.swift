import Foundation

/// Local matching of the user's own tools against the signed advisory list
/// (security plan v16 §9.5.4). Pure: an `Instance` is what the inventory
/// read from this machine (identity, versions, origin, candidates); the
/// result is one `ToolReport` per watched tool. Never says "safe": the best
/// result is "no known security issues (checked <date>)".
enum LocalTools {
    /// Bilingual text (status lines are shown in English or Italian).
    struct Text: Codable, Equatable {
        var en: String
        var it: String
        init(_ en: String, _ it: String) { self.en = en; self.it = it }
    }

    struct DebCandidate: Codable, Equatable {
        var binary: String
        var version: String
        /// Normalised source name and version of the EXACT candidate record
        /// (§9.5.4 step 3); nil when the record is missing or ambiguous.
        var sourceName: String? = nil
        var sourceVersion: String?
        /// The candidate comes from the identity's own distribution/release
        /// archive (incl. -security/-updates, ESM) per `apt-cache policy`.
        /// The candidate is listed under an accepted origin: the Release
        /// fields `o=` / `n=` apt reports for its package file match the
        /// identity's distribution and release (incl. -security, -updates,
        /// Ubuntu ESM). This is apt's labelling, not an independent check of
        /// signing keys or of Ubuntu Pro attachment (N2).
        var originOK: Bool
        var pocket: LocalAdvisory.Pocket?
        /// Why the candidate's own index cannot count as fresh (N2), if so.
        var indexProblem: Text? = nil
    }

    enum Candidates: Codable, Equatable {
        /// Read-only apt evidence for the binaries of the source; `problem`
        /// set when it cannot be used (lists too old, a query failed).
        case deb(list: [DebCandidate], asOf: Date, problem: Text?)
        /// Homebrew's cached catalogue version (brew itself is never run).
        case brew(version: String?, asOf: Date?)
        /// Vendor builds are updated from the vendor; no local candidate.
        case vendor
        case unavailable(Text)
    }

    /// One actually-used instance of a watched tool, as read from the local
    /// package database (§9.5.2: the instance that runs, not any copy).
    struct Instance: Codable, Equatable {
        /// v17: how a vendor build was installed (`nvm`, `pkg`, `tarball:<dir>`,
        /// `app`); picks the compiled fix wording. nil for package managers.
        var vendorVia: String? = nil
        var toolId: String
        var identity: LocalAdvisory.Identity
        /// As the package manager shows it (deb binary version, brew keg).
        var installedVersion: String
        /// What the advisory ranges are compared with (deb: the normalised
        /// SOURCE version; brew: the keg version incl. revision).
        var compareVersion: String
        /// The origin check failed (other origin, PPA, other tap, HEAD,
        /// unrecognised build): state unknown with this reason.
        var originProblem: Text?
        /// deb: the binary package owning the used file, then the other
        /// installed binaries of the same source and source version —
        /// names re-read from dpkg, validated locally.
        var binaries: [String]
        var candidates: Candidates
        var usedPath: String?
        /// Shown on the Security line but never messaged (UT rootfs: the
        /// UBports OTA updates it, no command could).
        var statusOnly: Text?
    }

    enum Resolution: Codable, Equatable {
        case present(Instance)
        /// Positively not installed (the package database was readable).
        case absent(toolId: String)
        /// Could not be determined; never removes a localvuln row.
        case unknown(toolId: String, reason: Text)

        var toolId: String {
            switch self {
            case .present(let i): return i.toolId
            case .absent(let t), .unknown(let t, _): return t
            }
        }
    }

    enum FixState: Codable, Equatable {
        case installable
        case notInstallable(Text)
        case noFix(LocalAdvisory.NoFixReason)
        /// Applies, but whether a fix is installable could not be checked.
        case unknown(Text)
    }

    struct AdvisoryResult: Codable, Equatable {
        var ids: [String]
        var primaryId: String
        var severity: ReleaseSecurity.Level
        var kev: Bool
        var fixedVersion: String?
        var fix: FixState
    }

    enum State: String, Codable {
        /// v18 (§9.5.10.1): no applicable advisory, but older than the
        /// vendor's latest security release for its line (Node).
        case behindSecurityRelease = "behind-security-release"
        case affectedFixInstallable = "affected-fix-installable"
        case affectedNotInstallable = "affected-not-installable"
        case affectedNoFix = "affected-no-fix"
        case noKnownIssue = "no-known-issue"
        case unknown
        case absent
    }

    /// Reserved for the §9.5.8 support floor (plan v16, added later): the
    /// matcher never sets it today; message and status code read it so the
    /// floor can arrive without changing their shape.
    struct FloorState: Codable, Equatable {
        var below: Bool
        var basis: String
    }

    /// How the user applies the fix; names come only from the local
    /// package database (validated again at render time).
    enum FixAction: Codable, Equatable {
        case apt([String])
        case brew(String)
        case cask(String)
        case vendor(vendor: String, product: String, minimum: String)
        /// v17 (§9.5.10.1): an official Node.js build; `via` = nvm | pkg |
        /// tarball, `major` from the local version, `root` the tarball
        /// directory name (validated locally).
        case node(via: String, major: String, minimum: String, root: String?)
        /// v18 (§9.5.10.2): LibreOffice.app from libreoffice.org.
        case libreoffice(minimum: String)
    }

    struct ToolReport: Codable, Equatable {
        var toolId: String
        var identityKey: String?
        var installedVersion: String?
        var state: State
        var reason: Text?
        var affected: [AdvisoryResult] = []
        /// Advisories that could not be evaluated (comparator, range).
        var unknownAdvisories = 0
        /// Coverage `partial` (size-trimmed list, owner decision F3).
        var trimmed = false
        var checkedAt: Date?
        var statusOnly: Text?
        var action: FixAction? = nil
        var floor: FloorState? = nil
        /// v18 (R17-3): `kind: release` records that apply (never part of
        /// `affected`, never "a known security problem").
        var releases: [AdvisoryResult] = []

        var kevAffected: Bool { affected.contains { $0.kev } }
        var level: ReleaseSecurity.Level {
            affected.contains { $0.severity == .critical } ? .critical : .recommended
        }
        var hasInstallableFix: Bool { affected.contains { $0.fix == .installable } }
        /// A KEV-listed applicable advisory without an installable fix.
        var kevWithoutFix: Bool { affected.contains { $0.kev && $0.fix != .installable } }
        /// V4: messaged states (fix installable; KEV without an installable fix).
        var messageable: Bool { statusOnly == nil && (hasInstallableFix || kevWithoutFix || releaseUpdateInstallable) }
        var releaseUpdateInstallable: Bool { releases.contains { $0.fix == .installable } }
    }

    // MARK: - Matching

    static func match(_ resolution: Resolution, list: LocalAdvisory.Document?, now: Date) -> ToolReport {
        switch resolution {
        case .absent(let t):
            return ToolReport(toolId: t, state: .absent)
        case .unknown(let t, let why):
            return ToolReport(toolId: t, state: .unknown, reason: why)
        case .present(let i):
            return match(i, list: list, now: now)
        }
    }

    static func match(_ i: Instance, list: LocalAdvisory.Document?, now: Date) -> ToolReport {
        var r = ToolReport(toolId: i.toolId, identityKey: i.identity.key, installedVersion: i.installedVersion,
                           state: .unknown, statusOnly: i.statusOnly)
        // Step 1: origin.
        if let why = i.originProblem { r.reason = why; return r }
        guard let list else {
            r.reason = Text("no current advisory list", "nessun elenco di avvisi aggiornato"); return r
        }
        // Step 2: coverage (positive, non-empty, set inclusion, no duplicates, fresh).
        switch coverage(for: i.identity, in: list, now: now) {
        case .unknown(let why):
            r.reason = why
            return r
        case .checked(let at, let trimmed):
            r.checkedAt = at
            r.trimmed = trimmed
        }
        let entry = list.entry(for: i.identity.key)
        let scheme = entry.flatMap { LocalToolsVersion.Scheme(rawValue: $0.scheme) }
        for a in entry?.advisories ?? [] where !a.withdrawn {
            guard let scheme, a.kind != .unsupported else { r.unknownAdvisories += 1; continue }
            // Step 3: applicability on the compare (source) version.
            guard let applies = LocalToolsVersion.isAffected(i.compareVersion, a.affected, scheme: scheme) else {
                r.unknownAdvisories += 1; continue
            }
            guard applies else {
                // v18-v20: the source's default is "unknown" outside its LISTED
                // SERIES; a version inside a listed series but past its fix is
                // simply not affected by it.
                if a.unknownOutside && !inListedSeries(i.compareVersion, a) { r.unknownAdvisories += 1 }
                continue
            }
            // Step 4: remediation.
            let (fixed, fix) = remediation(a, instance: i, scheme: scheme, now: now)
            let result = AdvisoryResult(ids: a.ids, primaryId: a.primaryId, severity: a.severity, kev: a.kev,
                                        fixedVersion: fixed, fix: fix)
            if a.kind == .release { r.releases.append(result) } else { r.affected.append(result) }
        }
        // v17: a version on a line the vendor no longer maintains is never
        // "no known issue" (positive advisories still count).
        var unmaintained: Text? = nil
        if let lines = entry?.maintainedLines, let major = i.compareVersion.split(separator: ".").first.map(String.init),
           !lines.contains(major) {
            unmaintained = Text("\(LocalTools.tool(i.toolId)?.name ?? i.toolId) \(major) no longer receives security fixes from its vendor",
                                "\(LocalTools.tool(i.toolId)?.name ?? i.toolId) \(major) non riceve più correzioni di sicurezza dal produttore")
        }
        // §9.5.12: below the release floor (or not comparable with it) the
        // pruned advisories would have been needed, so never "no known
        // issue" (positive advisories still count).
        var belowFloor: Text? = nil
        if let floor = entry?.floor, scheme == .deb,
           (LocalToolsVersion.compare(i.compareVersion, floor, scheme: .deb) ?? -1) < 0 {
            belowFloor = Text("this version is older than the oldest one this release ever shipped, so not every advisory was checked",
                              "questa versione è più vecchia della più vecchia mai distribuita per questa release, quindi non tutti gli avvisi sono stati controllati")
        }
        if !r.affected.isEmpty {
            if r.hasInstallableFix { r.state = .affectedFixInstallable }
            else if r.affected.contains(where: { if case .noFix = $0.fix { return false }; return true }) { r.state = .affectedNotInstallable }
            else { r.state = .affectedNoFix }
            r.reason = nil
            r.action = action(for: i, report: r, scheme: scheme)
        } else if !r.releases.isEmpty {
            r.state = .behindSecurityRelease
            r.reason = nil
            r.action = action(for: i, report: r, scheme: scheme)
        } else if let unmaintained {
            r.state = .unknown
            r.reason = unmaintained
        } else if let belowFloor {
            r.state = .unknown
            r.reason = belowFloor
        } else if r.unknownAdvisories > 0 {
            r.state = .unknown
            r.reason = Text("some advisories could not be evaluated for this version",
                            "alcuni avvisi non si possono valutare per questa versione")
        } else if r.trimmed {
            // F3: a trimmed identity never shows "no known issue".
            r.state = .unknown
            r.reason = Text("too many known issues to list; not every issue was checked",
                            "troppi problemi noti da elencare; non tutti sono stati controllati")
        } else {
            r.state = .noKnownIssue
        }
        return r
    }

    /// The advisory's listed series (its remediation lines, `N.N`) contain
    /// the version's major.minor.
    static func inListedSeries(_ version: String, _ a: LocalAdvisory.Advisory) -> Bool {
        let p = version.split(separator: ".")
        guard p.count >= 2 else { return false }
        let mm = "\(p[0]).\(p[1])"
        return a.remediation?.fixed.contains { $0.line == mm } ?? false
    }

    static func action(for i: Instance, report r: ToolReport, scheme: LocalToolsVersion.Scheme?) -> FixAction? {
        guard r.hasInstallableFix || r.releaseUpdateInstallable else { return nil }
        switch i.identity.kind {
        case .deb:
            let names = i.binaries.filter(validDebName)
            return names.isEmpty ? nil : .apt(names)
        case .brew:
            return i.binaries.first.flatMap { validBrewName($0) ? .brew($0) : nil }
        case .cask:
            return i.binaries.first.flatMap { validBrewName($0) ? .cask($0) : nil }
        case .vendor:
            var minimum: String? = nil
            for a in r.affected + r.releases where a.fix == .installable {
                guard let v = a.fixedVersion else { continue }
                if let m = minimum, let scheme, let c = LocalToolsVersion.compare(v, m, scheme: scheme), c <= 0 { continue }
                minimum = v
            }
            guard let minimum, let vendor = i.identity.vendor, let product = i.identity.product else { return nil }
            // Versions shown in text pass a strict pattern (they come from the list).
            guard minimum.range(of: "^[0-9]{1,4}(\\.[0-9]{1,4}){1,3}$", options: .regularExpression) != nil else { return nil }
            switch (vendor, product, i.vendorVia) {
            case ("nodejs.org", "node", let via?):
                guard let major = i.compareVersion.split(separator: ".").first.map(String.init),
                      major.range(of: "^[0-9]{1,4}$", options: .regularExpression) != nil else { return nil }
                if via.hasPrefix("tarball:") { return .node(via: "tarball", major: major, minimum: minimum, root: String(via.dropFirst(8))) }
                return [ "nvm", "pkg"].contains(via) ? .node(via: via, major: major, minimum: minimum, root: nil) : nil
            case ("documentfoundation", "libreoffice", _):
                return .libreoffice(minimum: minimum)
            default:
                return .vendor(vendor: vendor, product: product, minimum: minimum)
            }
        }
    }

    enum CoverageResult: Equatable {
        case checked(at: Date, trimmed: Bool)
        case unknown(Text)
    }

    static func coverage(for identity: LocalAdvisory.Identity, in list: LocalAdvisory.Document, now: Date) -> CoverageResult {
        guard let declared = list.declared[identity.ecosystemKey], !declared.isEmpty else {
            if identity.kind == .brew || identity.kind == .cask {
                return .unknown(Text("Homebrew tools are not matched against advisories; Briglia tells you when an update is waiting",
                                     "gli strumenti di Homebrew non sono confrontati con gli avvisi; Briglia ti avvisa quando c'è un aggiornamento in attesa"))
            }
            return .unknown(Text("this tool is not covered by the advisory list", "questo strumento non è coperto dall'elenco di avvisi"))
        }
        let rows = list.coverage.filter { $0.identity == identity.key }
        var bySource: [String: LocalAdvisory.CoverageRow] = [:]
        for row in rows {
            guard bySource[row.source] == nil else {
                return .unknown(Text("the advisory list has conflicting coverage for this tool", "l'elenco di avvisi ha una copertura contraddittoria per questo strumento"))
            }
            bySource[row.source] = row
        }
        var oldest: Date?, trimmed = false
        for source in declared {
            guard let row = bySource[source] else {
                return .unknown(Text("not every advisory source was checked for this tool", "non tutte le fonti di avvisi sono state controllate per questo strumento"))
            }
            switch row.status {
            case .ok?: break
            case .partial?: trimmed = true
            case .failed?, .notCovered?, nil:
                return .unknown(Text("an advisory source for this tool could not be checked", "una fonte di avvisi per questo strumento non è stata controllata"))
            }
            let age = now.timeIntervalSince(row.checkedAt)
            guard age <= LocalAdvisory.coverageFreshness, age >= -LocalAdvisory.futureSkew else {
                return .unknown(Text("the advisory check for this tool is more than 48 hours old", "il controllo degli avvisi per questo strumento ha più di 48 ore"))
            }
            oldest = min(oldest ?? row.checkedAt, row.checkedAt)
        }
        return .checked(at: oldest ?? now, trimmed: trimmed)
    }

    static func remediation(_ a: LocalAdvisory.Advisory, instance i: Instance, scheme: LocalToolsVersion.Scheme,
                            now: Date) -> (String?, FixState) {
        guard let rem = a.remediation else { return (nil, .noFix(a.noFixReason ?? .unknown)) }
        guard let fixed = LocalToolsVersion.fixedVersion(for: i.compareVersion, rem, scheme: scheme) else {
            return (nil, .notInstallable(Text("your release line does not receive this fix", "la tua linea di versioni non riceve questa correzione")))
        }
        func fixes(_ v: String) -> Bool? {
            guard let inside = LocalToolsVersion.isAffected(v, a.affected, scheme: scheme),
                  let c = LocalToolsVersion.compare(v, fixed, scheme: scheme) else { return nil }
            return !inside && c >= 0
        }
        switch i.candidates {
        case .vendor:
            return (fixed, .installable)
        case .unavailable(let why):
            return (fixed, .unknown(why))
        case .brew(let version, let asOf):
            guard let version, let asOf, now.timeIntervalSince(asOf) <= 24 * 3600 else {
                return (fixed, .unknown(Text("Homebrew's package information is more than a day old (run `brew update`)",
                                             "le informazioni dei pacchetti di Homebrew hanno più di un giorno (esegui `brew update`)")))
            }
            switch fixes(version) {
            case true?: return (fixed, .installable)
            case false?: return (fixed, .notInstallable(Text("the fix is not in Homebrew yet", "la correzione non è ancora in Homebrew")))
            case nil: return (fixed, .unknown(Text("Homebrew's version could not be compared", "la versione di Homebrew non si può confrontare")))
            }
        case .deb(let list, let asOf, let problem):
            if let problem { return (fixed, .unknown(problem)) }
            guard now.timeIntervalSince(asOf) <= 24 * 3600 else {
                return (fixed, .unknown(Text("the package information is more than a day old", "le informazioni sui pacchetti hanno più di un giorno")))
            }
            guard let owner = i.binaries.first, let cand = list.first(where: { $0.binary == owner }) else {
                return (fixed, .unknown(Text("no candidate information for this package", "nessuna informazione sul candidato per questo pacchetto")))
            }
            let esm = rem.pocket == .esmApps || rem.pocket == .esmInfra
            // The candidate must be a record of the SAME source package: a
            // larger version of another source proves nothing (R3).
            guard let srcName = cand.sourceName, let src = cand.sourceVersion else {
                return (fixed, .unknown(Text("the candidate's source package could not be identified", "non si riesce a identificare il pacchetto sorgente del candidato")))
            }
            if let why = cand.indexProblem { return (fixed, .unknown(why)) }
            guard srcName == i.identity.source else {
                return (fixed, .unknown(Text("the candidate is built from another source package", "il candidato è compilato da un altro pacchetto sorgente")))
            }
            if cand.originOK, fixes(src) == true,
               !esm || cand.pocket == .esmApps || cand.pocket == .esmInfra {
                return (fixed, .installable)
            }
            if esm, cand.pocket != .esmApps, cand.pocket != .esmInfra {
                return (fixed, .notInstallable(Text("a fix exists in Ubuntu Pro (ESM), but this system does not receive it",
                                                    "esiste una correzione in Ubuntu Pro (ESM), ma questo sistema non la riceve")))
            }
            return (fixed, .notInstallable(Text("the fix is not in your configured sources yet", "la correzione non è ancora nelle tue fonti configurate")))
        }
    }
}
