import Foundation

/// Debian / Ubuntu inventory (§9.5.2, §9.5.4 steps 1, 3, 4): dpkg owns the
/// used file; versions are normalised to the SOURCE version (Debian Policy
/// §5.6.1); origin and candidates come from read-only `apt-cache` queries
/// with apt's binary caches disabled, so nothing is written.
extension LocalTools {
    struct OSRelease: Equatable {
        var id: String
        var versionId: String
        var codename: String
    }

    static func parseOSRelease(_ data: Data?) -> OSRelease? {
        guard let data, data.count < 64 * 1024 else { return nil }
        var f: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            var v = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if v.count >= 2, (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
                v = String(v.dropFirst().dropLast())
            }
            f[String(line[..<eq])] = v
        }
        guard let id = f["ID"], let ver = f["VERSION_ID"], let code = f["VERSION_CODENAME"] ?? f["UBUNTU_CODENAME"],
              !id.isEmpty, !ver.isEmpty, !code.isEmpty else { return nil }
        return OSRelease(id: id, versionId: ver, codename: code)
    }

    struct DpkgPackage: Equatable {
        var name: String
        var version: String
        var sourceName: String
        var sourceVersion: String
    }

    /// Debian Policy §5.6.1: `Source: name (version)` → name, version;
    /// `Source: name` → name and the binary's Version; no Source → the
    /// binary's own name and Version. A binNMU therefore keeps its source
    /// version.
    static func normaliseSource(binary: String, version: String, source: String) -> (String, String)? {
        let s = source.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return (binary, version) }
        if let open = s.firstIndex(of: "(") {
            guard s.hasSuffix(")") else { return nil }
            let name = s[..<open].trimmingCharacters(in: .whitespaces)
            let ver = s[s.index(after: open)..<s.index(before: s.endIndex)].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !ver.isEmpty, !name.contains(" ") else { return nil }
            return (name, ver)
        }
        guard !s.contains(" ") else { return nil }
        return (s, version)
    }

    /// `dpkg-query -W -f '${binary:Package}\t${Version}\t${Source}\t${db:Status-Abbrev}\n'`.
    /// Only fully installed packages ("ii"); the architecture qualifier is
    /// kept as dpkg prints it.
    static func parseDpkgList(_ text: String) -> [String: DpkgPackage] {
        var out: [String: DpkgPackage] = [:]
        for line in text.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 4, f[3].hasPrefix("ii"), validDebName(f[0]), !f[1].isEmpty,
                  let (sn, sv) = normaliseSource(binary: f[0].split(separator: ":").first.map(String.init) ?? f[0],
                                                 version: f[1], source: f[2]) else { continue }
            out[f[0]] = DpkgPackage(name: f[0], version: f[1], sourceName: sn, sourceVersion: sv)
        }
        return out
    }

    /// `dpkg-query -S <path>` → the single owning package, or nil (none,
    /// several, or a diversion).
    static func parseDpkgSearch(_ text: String, path: String) -> String? {
        var owners: [String] = []
        for line in text.split(separator: "\n") where !line.hasPrefix("diversion by") {
            guard let sep = line.range(of: ": ") else { continue }
            guard String(line[sep.upperBound...]) == path else { continue }
            owners += line[..<sep.lowerBound].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let unique = Array(Set(owners))
        return unique.count == 1 && validDebName(unique[0]) ? unique[0] : nil
    }

    struct PolicyVersion: Equatable {
        var version: String
        var installed: Bool
        /// The package-file keys this version is available from.
        var files: [String]
    }

    struct PolicyPackage: Equatable {
        var installed: String?
        var candidate: String?
        var versions: [PolicyVersion]
    }

    /// Per-package `apt-cache policy a b c` output.
    static func parsePackagePolicy(_ text: String) -> [String: PolicyPackage] {
        var out: [String: PolicyPackage] = [:]
        var current: String?
        var pkg = PolicyPackage(installed: nil, candidate: nil, versions: [])
        func flush() { if let c = current { out[c] = pkg } }
        for raw in text.split(separator: "\n") {
            let line = String(raw)
            if !line.hasPrefix(" "), line.hasSuffix(":") {
                flush()
                current = String(line.dropLast())
                pkg = PolicyPackage(installed: nil, candidate: nil, versions: [])
                continue
            }
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("Installed: ") { let v = String(t.dropFirst(11)); pkg.installed = v == "(none)" ? nil : v; continue }
            if t.hasPrefix("Candidate: ") { let v = String(t.dropFirst(11)); pkg.candidate = v == "(none)" ? nil : v; continue }
            if t == "Version table:" { continue }
            let lead = line.prefix(while: { $0 == " " }).count
            let starred = t.hasPrefix("*** ")
            let parts = (starred ? String(t.dropFirst(4)) : t).split(separator: " ")
            if starred || (lead >= 3 && lead <= 6) {
                // A version line: "<version> <priority>".
                if parts.count == 2, Int(parts[1]) != nil {
                    pkg.versions.append(PolicyVersion(version: String(parts[0]), installed: starred, files: []))
                }
                continue
            }
            // A package-file line under the last version: "<prio> <file...>".
            if lead >= 7, let first = parts.first, Int(first) != nil, parts.count >= 2, !pkg.versions.isEmpty {
                pkg.versions[pkg.versions.count - 1].files.append(parts.dropFirst().joined(separator: " "))
            }
        }
        flush()
        return out
    }

    /// Global `apt-cache policy`: package-file key → its Release fields
    /// (`o=`, `n=`, …).
    static func parseGlobalPolicy(_ text: String) -> [String: [String: String]] {
        var out: [String: [String: String]] = [:]
        var current: String?
        for raw in text.split(separator: "\n") {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("release ") {
                guard let c = current else { continue }
                var fields: [String: String] = [:]
                for kv in t.dropFirst(8).split(separator: ",") {
                    let p = kv.split(separator: "=", maxSplits: 1).map(String.init)
                    if p.count == 2 { fields[p[0]] = p[1] }
                }
                out[c] = fields
                continue
            }
            let parts = t.split(separator: " ")
            if let first = parts.first, Int(first) != nil, parts.count >= 2 {
                current = parts.dropFirst().joined(separator: " ")
            } else if !t.hasPrefix("origin ") {
                current = nil
            }
        }
        return out
    }

    /// Whether a package-file's Release fields belong to the identity's
    /// distribution and release (incl. -security / -updates and Ubuntu ESM;
    /// never -backports or -proposed), and its pocket.
    static func originPocket(_ fields: [String: String]?, os: OSRelease) -> LocalAdvisory.Pocket? {
        guard let f = fields, let o = f["o"], let n = f["n"] else { return nil }
        guard n == os.codename || n.hasPrefix(os.codename + "-") else { return nil }
        if n.hasSuffix("-backports") || n.hasSuffix("-proposed") { return nil }
        switch (os.id, o) {
        case ("debian", "Debian"), ("ubuntu", "Ubuntu"): return .archive
        case ("ubuntu", "UbuntuESMApps"): return .esmApps
        case ("ubuntu", "UbuntuESM"): return .esmInfra
        default: return nil
        }
    }

    struct ShowRecord: Equatable {
        var package: String
        var architecture: String?
        var version: String
        var sourceName: String
        var sourceVersion: String
    }

    /// `apt-cache show a=1 b:arm64=2`: every stanza with its package,
    /// architecture, version and normalised source name and version.
    static func parseShowRecords(_ text: String) -> [ShowRecord] {
        var out: [ShowRecord] = []
        for stanza in text.components(separatedBy: "\n\n") {
            var f: [String: String] = [:]
            for line in stanza.split(separator: "\n") {
                guard let c = line.firstIndex(of: ":"), !line.hasPrefix(" ") else { continue }
                f[String(line[..<c])] = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
            }
            guard let p = f["Package"], let v = f["Version"],
                  let (sn, sv) = normaliseSource(binary: p, version: v, source: f["Source"] ?? "") else { continue }
            out.append(ShowRecord(package: p, architecture: f["Architecture"], version: v, sourceName: sn, sourceVersion: sv))
        }
        return out
    }

    /// The source of the EXACT candidate record for `binary` (possibly
    /// arch-qualified, as dpkg prints it) at `version`: the architecture
    /// must match (the qualifier, else the native one, or `all`); several
    /// matching records that disagree → nil (ambiguous, never a guess).
    static func candidateSource(_ records: [ShowRecord], binary: String, version: String,
                                nativeArch: String?) -> (String, String)? {
        let parts = binary.split(separator: ":", maxSplits: 1).map(String.init)
        let name = parts[0], arch = parts.count == 2 ? parts[1] : nativeArch
        let matches = records.filter { r in
            r.package == name && r.version == version
                && (arch == nil || r.architecture == arch || r.architecture == "all")
        }
        let distinct = Set(matches.map { "\($0.sourceName)\u{0}\($0.sourceVersion)" })
        guard distinct.count == 1, let m = matches.first else { return nil }
        return (m.sourceName, m.sourceVersion)
    }

    /// Paths of mapped shared objects (`/proc/self/maps`), deleted mappings excluded.
    static func mappedLibrary(_ maps: String, prefix: String) -> String? {
        for line in maps.split(separator: "\n") where !line.hasSuffix("(deleted)") {
            guard let slash = line.firstIndex(of: "/") else { continue }
            let path = String(line[slash...])
            if (path as NSString).lastPathComponent.hasPrefix(prefix) { return path }
        }
        return nil
    }
}

/// One evaluation pass over a Debian-family machine.
struct DebInventory {
    let probe: LocalTools.Probe
    typealias T = LocalTools

    func aptCache(_ args: [String]) -> (Int32, String)? {
        guard let apt = probe.findBinary("apt-cache") else { return nil }
        return probe.run("/usr/bin/env", ["LC_ALL=C", apt, "-o", "Dir::Cache::pkgcache=", "-o", "Dir::Cache::srcpkgcache="] + args,
                         T.probeTimeout)
    }

    func run() -> [T.Resolution] {
        guard let os = T.parseOSRelease(probe.readData("/etc/os-release")), ["debian", "ubuntu"].contains(os.id) else {
            let why = T.Text("this Linux distribution is not covered by the advisory list", "questa distribuzione Linux non è coperta dall'elenco di avvisi")
            return T.watchlist.map { .unknown(toolId: $0.id, reason: why) }
        }
        guard let dpkgQuery = probe.findBinary("dpkg-query") else {
            return T.watchlist.map { .unknown(toolId: $0.id, reason: T.Text("dpkg-query is not available", "dpkg-query non è disponibile")) }
        }
        let (st, listText) = probe.run(dpkgQuery, ["-W", "-f", "${binary:Package}\t${Version}\t${Source}\t${db:Status-Abbrev}\n"], T.probeTimeout)
        guard st == 0 else {
            return T.watchlist.map { .unknown(toolId: $0.id, reason: T.Text("the package database could not be read", "il database dei pacchetti non si può leggere")) }
        }
        let installed = T.parseDpkgList(listText)
        let maps = probe.platform == .linux ? probe.readData("/proc/self/maps").map { String(decoding: $0, as: UTF8.self) } : nil

        // Pass 1: owning package per tool.
        var owners: [(tool: T.WatchTool, owner: String?, path: String?, reason: T.Text?)] = []
        for tool in T.watchlist {
            owners.append(owner(of: tool, installed: installed, dpkgQuery: dpkgQuery, maps: maps))
        }
        // Pass 2: one policy query, one show query for every binary involved.
        var binariesByTool: [String: [String]] = [:]
        for o in owners {
            guard let owner = o.owner, let pkg = installed[owner] else { continue }
            let same = installed.values
                .filter { $0.sourceName == pkg.sourceName && $0.sourceVersion == pkg.sourceVersion && $0.name != owner }
                .map(\.name).sorted()
            binariesByTool[o.tool.id] = [owner] + same
        }
        let allBinaries = Array(Set(binariesByTool.values.flatMap { $0 })).sorted()
        let now = probe.now()
        var policy: [String: T.PolicyPackage]? = nil, global: [String: [String: String]]? = nil
        if !allBinaries.isEmpty, let (s1, g) = aptCache(["policy"]), s1 == 0,
           let (s2, per) = aptCache(["policy"] + allBinaries), s2 == 0 {
            global = T.parseGlobalPolicy(g)
            policy = T.parsePackagePolicy(per)
        }
        var showKeys: [String] = []
        for b in allBinaries { if let c = policy?[b]?.candidate { showKeys.append("\(b)=\(c)") } }
        var records: [T.ShowRecord]? = nil
        if !showKeys.isEmpty, let (s3, show) = aptCache(["show"] + showKeys), s3 == 0 { records = T.parseShowRecords(show) }
        let nativeArch: String? = {
            guard let dpkg = probe.findBinary("dpkg") else { return nil }
            let (st, out) = probe.run(dpkg, ["--print-architecture"], T.probeTimeout)
            let a = out.trimmingCharacters(in: .whitespacesAndNewlines)
            return st == 0 && a.range(of: "^[a-z0-9-]{1,32}$", options: .regularExpression) != nil ? a : nil
        }()

        return owners.map { o in
            guard let owner = o.owner, let pkg = installed[owner] else {
                if let reason = o.reason { return .unknown(toolId: o.tool.id, reason: reason) }
                return .absent(toolId: o.tool.id)
            }
            let identity = LocalAdvisory.Identity(kind: .deb, distro: os.id, release: os.versionId, source: pkg.sourceName)
            let binaries = binariesByTool[o.tool.id] ?? [owner]
            var originProblem: T.Text? = nil
            if let policy, let global {
                let installedLine = policy[owner]?.versions.first { $0.installed && $0.version == pkg.version }
                let ok = installedLine?.files.contains { T.originPocket(global[$0], os: os) != nil } ?? false
                if !ok {
                    originProblem = T.Text("installed from a source other than \(os.id) \(os.versionId) (or no longer in its archive)",
                                           "installato da una fonte diversa da \(os.id) \(os.versionId) (o non più nel suo archivio)")
                }
            } else {
                originProblem = T.Text("the package origin could not be checked", "l'origine del pacchetto non si può verificare")
            }
            var cands: [T.DebCandidate] = []
            if let policy, let global {
                for b in binaries {
                    guard let p = policy[b], let c = p.candidate, let line = p.versions.first(where: { $0.version == c }) else { continue }
                    let pockets = line.files.compactMap { T.originPocket(global[$0], os: os) }
                    let pocket: LocalAdvisory.Pocket? = pockets.contains(.esmApps) ? .esmApps : pockets.contains(.esmInfra) ? .esmInfra : pockets.first
                    let src = records.flatMap { T.candidateSource($0, binary: b, version: c, nativeArch: nativeArch) }
                    let accepted = line.files.filter { T.originPocket(global[$0], os: os) != nil }
                    cands.append(T.DebCandidate(binary: b, version: c, sourceName: src?.0, sourceVersion: src?.1,
                                                originOK: pocket != nil, pocket: pocket,
                                                indexProblem: indexProblem(fileKeys: accepted, now: now)))
                }
            }
            let problem: T.Text? = (policy == nil ? T.Text("apt's package information could not be read", "le informazioni dei pacchetti di apt non si possono leggere") : nil)
            let statusOnly = probe.platform == .ubuntuTouch
                ? T.Text("system packages on Ubuntu Touch are updated by the UBports OTA (System Settings → Updates)",
                         "su Ubuntu Touch i pacchetti di sistema si aggiornano con l'OTA di UBports (Impostazioni di sistema → Aggiornamenti)")
                : nil
            return .present(T.Instance(toolId: o.tool.id, identity: identity, installedVersion: pkg.version,
                                       compareVersion: pkg.sourceVersion, originProblem: originProblem, binaries: binaries,
                                       candidates: .deb(list: cands, asOf: now, problem: problem), usedPath: o.path,
                                       statusOnly: statusOnly))
        }
    }

    /// The package that owns the file the tool would use, or why not.
    func owner(of tool: T.WatchTool, installed: [String: T.DpkgPackage], dpkgQuery: String,
               maps: String?) -> (tool: T.WatchTool, owner: String?, path: String?, reason: T.Text?) {
        var path: String? = nil
        for exe in tool.executables { if let p = probe.findBinary(exe) { path = p; break } }
        if tool.rendererBrowser {
            switch T.rendererPathBrowser(probe) {
            case .found(let p): path = p
            case .notFound: path = nil
            case .ambiguous:
                return (tool, nil, nil, T.Text("PATH has an empty or relative entry, so the browser the PDF renderer uses depends on its working directory",
                                               "il PATH ha una voce vuota o relativa: il browser usato per i PDF dipende dalla sua cartella di lavoro"))
            }
        }
        if path == nil, let lib = tool.mappedLibrary, let maps { path = T.mappedLibrary(maps, prefix: lib) }
        if let p = path {
            let real = probe.resolve(p) ?? p
            if probe.owned(real) || probe.owned(p) || probe.isToolchainWrapper(p) {
                return (tool, nil, p, T.Text("Briglia's own copy (checked by `briglia toolchain upgrade` / Briglia releases)",
                                             "copia di Briglia (controllata da `briglia toolchain upgrade` / dalle versioni di Briglia)"))
            }
            for candidate in Array(Set([p, real])).sorted() {
                let (st, out) = probe.run(dpkgQuery, ["-S", candidate], T.probeTimeout)
                if st == 0, let pkg = T.parseDpkgSearch(out, path: candidate), installed[pkg] != nil { return (tool, pkg, p, nil) }
            }
            return (tool, nil, p, T.Text("\(p) is not installed from a system package", "\(p) non è installato da un pacchetto di sistema"))
        }
        for name in tool.debPackages {
            if installed[name] != nil { return (tool, name, nil, nil) }
            if let q = installed.keys.first(where: { $0.hasPrefix(name + ":") }) { return (tool, q, nil, nil) }
        }
        if tool.mappedLibrary != nil, maps == nil {
            return (tool, nil, nil, T.Text("the loaded libraries could not be read", "le librerie caricate non si possono leggere"))
        }
        return (tool, nil, nil, nil)
    }

    /// N2: freshness of the candidate's OWN index. The package-file key
    /// ("http://host/path suite/component arch Packages") names the
    /// Release file apt downloaded for that suite
    /// (`/var/lib/apt/lists/host_path_dists_suite_InRelease`); its age must
    /// be ≤ 7 days (exact seconds). Any other layout (flat repositories,
    /// file: URIs) or a missing file → no freshness evidence.
    func indexProblem(fileKeys: [String], now: Date) -> T.Text? {
        var ages: [TimeInterval] = []
        for key in fileKeys {
            guard let date = T.releaseFileName(forPackageFile: key).flatMap({ name -> Date? in
                ["_InRelease", "_Release"].lazy.compactMap { self.probe.modificationDate("/var/lib/apt/lists/" + name + $0) }.first
            }) else { continue }
            ages.append(now.timeIntervalSince(date))
        }
        guard let youngest = ages.min() else {
            return T.Text("the age of this package's index cannot be established", "non si riesce a stabilire l'età dell'indice di questo pacchetto")
        }
        guard youngest <= 7 * 86_400 else {
            let days = Int(youngest / 86_400)
            return T.Text("this package's index is \(days) days old (run `sudo apt update`)",
                          "l'indice di questo pacchetto ha \(days) giorni (esegui `sudo apt update`)")
        }
        return nil
    }
}

extension LocalTools {
    /// apt's list-file stem for a `http(s)://host/path suite/component …`
    /// package-file key; nil for any other shape.
    static func releaseFileName(forPackageFile key: String) -> String? {
        let parts = key.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let uri = String(parts[0]), suite = parts[1].split(separator: "/").first.map(String.init) ?? ""
        guard let scheme = uri.range(of: "://"), ["http", "https"].contains(String(uri[..<scheme.lowerBound])),
              !suite.isEmpty, suite.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else { return nil }
        var rest = String(uri[scheme.upperBound...])
        while rest.hasSuffix("/") { rest.removeLast() }
        guard !rest.isEmpty, !rest.contains("@") else { return nil }
        return rest.replacingOccurrences(of: "/", with: "_") + "_dists_" + suite
    }
}
