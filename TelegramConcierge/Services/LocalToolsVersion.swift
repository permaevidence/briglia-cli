import Foundation

/// Version comparison for the local-tools check (security plan §7.4, §9.5.4).
/// Every comparator returns nil ("unknown") for anything it cannot order
/// with certainty; unknown never counts as "not affected" or as a fix.
enum LocalToolsVersion {
    enum Scheme: String {
        case deb, brew, semver, dotted
    }

    /// -1 / 0 / +1, or nil when either version is not valid for the scheme.
    static func compare(_ a: String, _ b: String, scheme: Scheme) -> Int? {
        switch scheme {
        case .deb: return debCompare(a, b)
        case .brew: return brewCompare(a, b)
        case .semver: return semverCompare(a, b)
        case .dotted: return dottedCompare(a, b)
        }
    }

    // MARK: - Debian (dpkg's algorithm, deb-version(7))

    struct DebVersion: Equatable {
        var epoch: Int
        var upstream: String
        var revision: String
    }

    static func parseDeb(_ raw: String) -> DebVersion? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, s.utf8.count <= 256, !s.contains(" ") else { return nil }
        var epoch = 0
        var rest = Substring(s)
        if let colon = rest.firstIndex(of: ":") {
            let e = rest[..<colon]
            guard !e.isEmpty, e.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(e), n < 1_000_000 else { return nil }
            epoch = n
            rest = rest[rest.index(after: colon)...]
        }
        var upstream = String(rest), revision = ""
        if let dash = rest.lastIndex(of: "-") {
            upstream = String(rest[..<dash])
            revision = String(rest[rest.index(after: dash)...])
            guard !revision.isEmpty else { return nil }
        }
        guard let first = upstream.first, first.isASCII, first.isNumber else { return nil }
        let upstreamOK = upstream.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".+~-:".contains($0)) }
        let revisionOK = revision.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".+~".contains($0)) }
        guard upstreamOK, revisionOK else { return nil }
        return DebVersion(epoch: epoch, upstream: upstream, revision: revision)
    }

    static func debCompare(_ a: String, _ b: String) -> Int? {
        guard let x = parseDeb(a), let y = parseDeb(b) else { return nil }
        if x.epoch != y.epoch { return x.epoch < y.epoch ? -1 : 1 }
        let u = verrevcmp(x.upstream, y.upstream)
        if u != 0 { return u < 0 ? -1 : 1 }
        let r = verrevcmp(x.revision, y.revision)
        return r == 0 ? 0 : (r < 0 ? -1 : 1)
    }

    private static func order(_ c: UInt8?) -> Int {
        guard let c else { return 0 }
        if c >= 48 && c <= 57 { return 0 }
        if (c >= 65 && c <= 90) || (c >= 97 && c <= 122) { return Int(c) }
        if c == 126 { return -1 } // "~"
        return Int(c) + 256
    }

    private static func verrevcmp(_ sa: String, _ sb: String) -> Int {
        let a = Array(sa.utf8), b = Array(sb.utf8)
        var i = 0, j = 0
        func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }
        while i < a.count || j < b.count {
            var firstDiff = 0
            while (i < a.count && !isDigit(a[i])) || (j < b.count && !isDigit(b[j])) {
                let ac = order(i < a.count ? a[i] : nil), bc = order(j < b.count ? b[j] : nil)
                if ac != bc { return ac - bc }
                i += 1; j += 1
            }
            while i < a.count && a[i] == 48 { i += 1 }
            while j < b.count && b[j] == 48 { j += 1 }
            while i < a.count && isDigit(a[i]) && j < b.count && isDigit(b[j]) {
                if firstDiff == 0 { firstDiff = Int(a[i]) - Int(b[j]) }
                i += 1; j += 1
            }
            if i < a.count && isDigit(a[i]) { return 1 }
            if j < b.count && isDigit(b[j]) { return -1 }
            if firstDiff != 0 { return firstDiff }
        }
        return 0
    }

    // MARK: - Homebrew (version + `_revision`)

    enum BrewToken: Equatable { case number(Int), pre(String), other(String) }

    /// "7.1.1_3" → tokens of 7.1.1 and revision 3. HEAD and anything outside
    /// the plain alphanumeric/dotted form → nil.
    static func parseBrew(_ raw: String) -> (tokens: [BrewToken], revision: Int)? {
        guard !raw.isEmpty, raw.utf8.count <= 128, !raw.uppercased().hasPrefix("HEAD") else { return nil }
        var version = Substring(raw), revision = 0
        if let us = raw.lastIndex(of: "_") {
            let r = raw[raw.index(after: us)...]
            guard !r.isEmpty, r.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(r) else { return nil }
            revision = n
            version = raw[..<us]
        }
        guard let first = version.first, first.isASCII, first.isNumber,
              version.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-+".contains($0)) }) else { return nil }
        var tokens: [BrewToken] = []
        var current = "", isNum = false
        func flush() {
            guard !current.isEmpty else { return }
            if isNum, let n = Int(current) { tokens.append(.number(n)) }
            else {
                let l = current.lowercased()
                tokens.append(["alpha", "a", "beta", "b", "rc", "pre", "dev"].contains(l) ? .pre(l) : .other(l))
            }
            current = ""
        }
        for c in version {
            if !(c.isLetter || c.isNumber) { flush(); continue }
            let num = c.isNumber
            if !current.isEmpty && num != isNum { flush() }
            isNum = num
            current.append(c)
        }
        flush()
        guard tokens.allSatisfy({ if case .number(let n) = $0 { return n < Int(Int32.max) }; return true }) else { return nil }
        return (tokens, revision)
    }

    static func brewCompare(_ a: String, _ b: String) -> Int? {
        guard let x = parseBrew(a), let y = parseBrew(b) else { return nil }
        let n = max(x.tokens.count, y.tokens.count)
        for i in 0..<n {
            let p = i < x.tokens.count ? x.tokens[i] : nil, q = i < y.tokens.count ? y.tokens[i] : nil
            guard let c = brewTokenCompare(p, q) else { return nil }
            if c != 0 { return c }
        }
        return x.revision == y.revision ? 0 : (x.revision < y.revision ? -1 : 1)
    }

    private static func brewTokenCompare(_ p: BrewToken?, _ q: BrewToken?) -> Int? {
        switch (p, q) {
        case (nil, nil): return 0
        case (nil, .number(let m)?): return m == 0 ? 0 : -1
        case (.number(let m)?, nil): return m == 0 ? 0 : 1
        case (nil, .pre?): return 1
        case (.pre?, nil): return -1
        case (nil, .other?), (.other?, nil): return nil
        case (.number(let x)?, .number(let y)?): return x == y ? 0 : (x < y ? -1 : 1)
        case (.number?, .pre?): return 1
        case (.pre?, .number?): return -1
        case (.pre(let x)?, .pre(let y)?):
            let rank = ["dev": 0, "alpha": 1, "a": 1, "beta": 2, "b": 2, "pre": 3, "rc": 3]
            guard let rx = rank[x], let ry = rank[y] else { return nil }
            return rx == ry ? 0 : (rx < ry ? -1 : 1)
        default: return nil
        }
    }

    // MARK: - SemVer 2.0.0 (a leading "v" is accepted: Node prints "v22.1.0")

    static func parseSemver(_ raw: String) -> (core: [Int], pre: [String]?)? {
        var s = raw
        if s.hasPrefix("v") { s.removeFirst() }
        if let plus = s.firstIndex(of: "+") { s = String(s[..<plus]) }
        var pre: [String]? = nil
        if let dash = s.firstIndex(of: "-") {
            let p = s[s.index(after: dash)...].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !p.isEmpty, p.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } })
            else { return nil }
            pre = p
            s = String(s[..<dash])
        }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var core: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.allSatisfy({ $0.isASCII && $0.isNumber }), !(p.count > 1 && p.hasPrefix("0")),
                  let n = Int(p) else { return nil }
            core.append(n)
        }
        return (core, pre)
    }

    static func semverCompare(_ a: String, _ b: String) -> Int? {
        guard let x = parseSemver(a), let y = parseSemver(b) else { return nil }
        for i in 0..<3 where x.core[i] != y.core[i] { return x.core[i] < y.core[i] ? -1 : 1 }
        switch (x.pre, y.pre) {
        case (nil, nil): return 0
        case (nil, _?): return 1
        case (_?, nil): return -1
        case (let p?, let q?):
            for i in 0..<min(p.count, q.count) {
                let pn = Int(p[i]), qn = Int(q[i])
                switch (pn, qn) {
                case (let m?, let n?): if m != n { return m < n ? -1 : 1 }
                case (nil, nil): if p[i] != q[i] { return p[i] < q[i] ? -1 : 1 }
                case (_?, nil): return -1
                case (nil, _?): return 1
                }
            }
            return p.count == q.count ? 0 : (p.count < q.count ? -1 : 1)
        }
    }

    // MARK: - Dotted numeric (vendor builds: Chrome 130.0.6723.58, LibreOffice 24.8.2.1)

    static func dottedCompare(_ a: String, _ b: String) -> Int? {
        func parts(_ s: String) -> [Int]? {
            let p = s.split(separator: ".", omittingEmptySubsequences: false)
            guard !p.isEmpty, p.count <= 8 else { return nil }
            var out: [Int] = []
            for x in p {
                guard !x.isEmpty, x.count <= 9, x.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(x) else { return nil }
                out.append(n)
            }
            return out
        }
        guard let x = parts(a), let y = parts(b) else { return nil }
        for i in 0..<max(x.count, y.count) {
            let m = i < x.count ? x[i] : 0, n = i < y.count ? y[i] : 0
            if m != n { return m < n ? -1 : 1 }
        }
        return 0
    }

    // MARK: - OSV range evaluation (§9.5.3 `affected`)

    /// true = inside the advisory's applicability; false = outside (before
    /// `introduced`, in a gap, past `fixed`, after `last_affected`, at or
    /// past `limit`); nil = cannot be decided (unsupported range type or
    /// event, a version the comparator rejects).
    static func isAffected(_ version: String, _ affected: LocalAdvisory.Affected, scheme: Scheme) -> Bool? {
        guard !affected.unknown, !(affected.ranges.isEmpty && affected.versions.isEmpty) else { return nil }
        var anyUnknown = false
        // The union: a listed version OR any range (OSV `affected` semantics).
        for v in affected.versions {
            guard let c = compare(version, v, scheme: scheme) else { anyUnknown = true; continue }
            if c == 0 { return true }
        }
        for r in affected.ranges {
            switch inRange(version, r, scheme: scheme) {
            case true?: return true
            case nil: anyUnknown = true
            case false?: break
            }
        }
        return anyUnknown ? nil : false
    }

    static func inRange(_ v: String, _ range: LocalAdvisory.Range, scheme: Scheme) -> Bool? {
        guard !range.unsupported else { return nil }
        if range.type == "SEMVER", scheme != .semver { return nil }
        // Sort events by version; introduced "0" is the minimum.
        func key(_ e: LocalAdvisory.Event) -> String { e.version }
        var sorted: [LocalAdvisory.Event] = []
        for e in range.events {
            var idx = sorted.count
            for (i, s) in sorted.enumerated() {
                guard let c = eventOrder(e, s, scheme: scheme) else { return nil }
                if c < 0 { idx = i; break }
            }
            sorted.insert(e, at: idx)
        }
        var affected = false
        for e in sorted {
            switch e.kind {
            case .introduced:
                if e.version == "0" { affected = true; continue }
                guard let c = compare(v, e.version, scheme: scheme) else { return nil }
                if c >= 0 { affected = true }
            case .fixed:
                guard let c = compare(v, e.version, scheme: scheme) else { return nil }
                if c >= 0 { affected = false }
            case .lastAffected:
                guard let c = compare(v, e.version, scheme: scheme) else { return nil }
                if c > 0 { affected = false }
            case .limit:
                guard let c = compare(v, e.version, scheme: scheme) else { return nil }
                if c >= 0 { return false }
            }
        }
        return affected
    }

    /// Event ordering: by version ("0" introduced first); on equal versions
    /// introduced sorts before the others.
    private static func eventOrder(_ a: LocalAdvisory.Event, _ b: LocalAdvisory.Event, scheme: Scheme) -> Int? {
        let az = a.kind == .introduced && a.version == "0", bz = b.kind == .introduced && b.version == "0"
        if az || bz { return az == bz ? 0 : (az ? -1 : 1) }
        guard let c = compare(a.version, b.version, scheme: scheme) else { return nil }
        if c != 0 { return c }
        if a.kind == b.kind { return 0 }
        return a.kind == .introduced ? -1 : (b.kind == .introduced ? 1 : 0)
    }

    /// The remediation's fixed version that applies to `version`'s release
    /// line (a version whose line has no entry has no applicable fix).
    static func fixedVersion(for version: String, _ r: LocalAdvisory.Remediation, scheme: Scheme) -> String? {
        if let any = r.fixed.first(where: { $0.line == nil }) { return any.version }
        let line: String?
        switch scheme {
        case .semver: line = parseSemver(version).map { String($0.core[0]) }
        case .dotted, .brew: line = version.split(separator: ".").first.map(String.init)
        case .deb: line = nil
        }
        guard let line else { return nil }
        return r.fixed.first(where: { $0.line == line })?.version
    }
}
