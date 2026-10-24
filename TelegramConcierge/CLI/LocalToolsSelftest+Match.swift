import Foundation

extension LocalToolsSelftest {
    static func cmp(_ t: Tally, _ a: String, _ op: String, _ b: String, _ s: LocalToolsVersion.Scheme) {
        let c = LocalToolsVersion.compare(a, b, scheme: s)
        let ok: Bool
        switch op {
        case "<": ok = c == -1
        case ">": ok = c == 1
        case "=": ok = c == 0
        default: ok = c == nil
        }
        t.check("version[\(s.rawValue)]: \(a) \(op) \(b)", ok, "got \(c.map(String.init) ?? "nil")")
    }

    static func versionGroup(_ t: Tally) {
        for (a, op, b) in [("1.0", "<", "1.0-1"), ("1.0~rc1", "<", "1.0"), ("1:0.9", ">", "2.0"), ("1.0-1", "<", "1.0-1+b1"),
                           ("7:5.1.6-0+deb12u1", "<", "7:5.1.6-0+deb12u2"), ("1.2.3", "=", "1.2.3-0"), ("1.0a", ">", "1.0"),
                           ("1.0.0", ">", "1.0"), ("1.0+dfsg", ">", "1.0"), ("0001", "=", "1"), ("2.30-2", ">", "2.3-9"),
                           ("1.0~~", "<", "1.0~"), ("", "?", "1.0"), ("a1.0", "?", "1.0"), ("1:", "?", "1.0"), ("1.0-", "?", "1.0")] {
            cmp(t, a, op, b, .deb)
        }
        for (a, op, b) in [("7.1.1_3", ">", "7.1.1_2"), ("7.1.1", "<", "7.1.2"), ("7.1", "=", "7.1.0"), ("1.0rc1", "<", "1.0"),
                           ("2.0_1", ">", "2.0"), ("HEAD-abc123", "?", "1.0"), ("3.14.9_1", "<", "3.14.10")] {
            cmp(t, a, op, b, .brew)
        }
        for (a, op, b) in [("v22.1.0", ">", "22.0.9"), ("1.0.0-alpha", "<", "1.0.0"), ("1.0.0-alpha.1", "<", "1.0.0-beta"),
                           ("1.0.0+build.5", "=", "1.0.0"), ("01.0.0", "?", "1.0.0"), ("1.0", "?", "1.0.0")] {
            cmp(t, a, op, b, .semver)
        }
        for (a, op, b) in [("130.0.6723.58", "<", "130.0.6723.59"), ("24.8", "=", "24.8.0"), ("1.a", "?", "1.0")] {
            cmp(t, a, op, b, .dotted)
        }
    }

    static func ranges(_ events: [[String: String]]...) -> LocalAdvisory.Affected {
        .ranges(events.map { ev in
            LocalAdvisory.Range(type: "ECOSYSTEM", events: ev.map { e in
                LocalAdvisory.Event(kind: LocalAdvisory.EventKind(rawValue: e.keys.first!)!, version: e.values.first!)
            }, unsupported: false)
        })
    }

    static func aff(_ t: Tally, _ label: String, _ v: String, _ a: LocalAdvisory.Affected, _ s: LocalToolsVersion.Scheme, _ want: Bool?) {
        let got = LocalToolsVersion.isAffected(v, a, scheme: s)
        t.check("ranges: \(label)", got == want, "got \(got.map(String.init) ?? "nil")")
    }

    static func rangesGroup(_ t: Tally) {
        let one = ranges([["introduced": "5.0"], ["fixed": "5.2"]])
        aff(t, "before introduced → not affected", "4.9", one, .dotted, false)
        aff(t, "inside [introduced, fixed) → affected", "5.1", one, .dotted, true)
        aff(t, "at fixed → not affected", "5.2", one, .dotted, false)
        let gaps = ranges([["introduced": "1.0"], ["fixed": "1.2"], ["introduced": "2.0"], ["fixed": "2.3"]])
        aff(t, "gap between two intervals → not affected", "1.5", gaps, .dotted, false)
        aff(t, "second interval → affected", "2.1", gaps, .dotted, true)
        aff(t, "last_affected inclusive", "3.0", ranges([["introduced": "0"], ["last_affected": "3.0"]]), .dotted, true)
        aff(t, "after last_affected → not affected", "3.0.1", ranges([["introduced": "0"], ["last_affected": "3.0"]]), .dotted, false)
        aff(t, "at/after limit → not affected", "2.5", ranges([["introduced": "0"], ["limit": "2.0"]]), .dotted, false)
        let branches = ranges([["introduced": "20.0.0"], ["fixed": "20.19.6"]], [["introduced": "22.0.0"], ["fixed": "22.21.1"]])
        aff(t, "parallel vendor branch not covered → not affected", "21.5.0", branches, .semver, false)
        aff(t, "affected branch → affected", "22.20.0", branches, .semver, true)
        aff(t, "fixed on its own branch → not affected", "20.19.6", branches, .semver, false)
        aff(t, "Debian backport equal to the distro fix → not affected (upstream looks older)",
            "7:5.1.6-0+deb12u2", ranges([["introduced": "0"], ["fixed": "7:5.1.6-0+deb12u2"]]), .deb, false)
        aff(t, "explicit version list: listed → affected", "1.4", .versions(["1.3", "1.4"]), .dotted, true)
        aff(t, "explicit version list: not listed → not affected", "1.5", .versions(["1.3", "1.4"]), .dotted, false)
        aff(t, "affected: unknown → unknown", "1.0", .unknown, .dotted, nil)
        aff(t, "comparator cannot parse → unknown", "7:5.1.6-0+deb12u1", one, .semver, nil)
        aff(t, "unsupported range → unknown", "1.0", .ranges([LocalAdvisory.Range(type: "GIT", events: [], unsupported: true)]), .dotted, nil)
    }

    static func coverageGroup(_ t: Tally) {
        let key = "deb:debian:12:ffmpeg"
        let entry = LTF.debEntry([LTF.adv(["CVE-2099-0001"])])
        func state(_ cov: [[String: Any]], _ entries: [[String: Any]] = [], declared: [String: [String]] = LTF.debian12) -> LocalTools.ToolReport {
            LocalTools.match(LTF.debInstance(), list: LTF.doc(LTF.payload(declared: declared, coverage: cov, entries: entries)), now: LTF.now)
        }
        t.check("coverage: all declared sources ok → checked (no entries → no known issue)", state(LTF.covAll(key)).state == .noKnownIssue)
        t.check("coverage: a failed source → unknown even with no entries",
                state([LTF.cov(key, "osv:Debian:12", "failed"), LTF.cov(key, "cisa-kev")]).state == .unknown)
        t.check("coverage: a failed source → unknown even with an applicable entry",
                state([LTF.cov(key, "osv:Debian:12", "failed"), LTF.cov(key, "cisa-kev")], [entry]).state == .unknown)
        t.check("coverage: not-covered → unknown", state([LTF.cov(key, "osv:Debian:12", "not-covered"), LTF.cov(key, "cisa-kev")]).state == .unknown)
        t.check("coverage: stale (> 48 h) → unknown", state(LTF.covAll(key, at: LTF.now.addingTimeInterval(-49 * 3600))).state == .unknown)
        t.check("coverage: no rows for the identity → unknown (never vacuous)", state([]).state == .unknown)
        t.check("coverage: a declared source missing → unknown", state([LTF.cov(key, "osv:Debian:12")]).state == .unknown)
        t.check("coverage: two ok rows for one source while another declared source has none → unknown",
                state([LTF.cov(key, "osv:Debian:12"), LTF.cov(key, "osv:Debian:12", "ok", LTF.now.addingTimeInterval(-60))]).state == .unknown)
        t.check("coverage: duplicate rows (both sources present) → unknown",
                state(LTF.covAll(key) + [LTF.cov(key, "cisa-kev", "ok", LTF.now.addingTimeInterval(-60))]).state == .unknown)
        t.check("coverage: a row for an undeclared source is ignored", state(LTF.covAll(key) + [LTF.cov(key, "extra")]).state == .noKnownIssue)
        t.check("coverage: unknown status value → unknown",
                state([LTF.cov(key, "osv:Debian:12", "maybe"), LTF.cov(key, "cisa-kev")]).state == .unknown)
        t.check("coverage: ecosystem not declared → unknown", state(LTF.covAll(key), declared: ["deb:debian:13": ["x"]]).state == .unknown)
        // Owner decision F3 (v16): partial = size-trimmed after a complete fetch.
        let trimmedHit = state([LTF.cov(key, "osv:Debian:12", "partial"), LTF.cov(key, "cisa-kev")], [entry])
        t.check("F3: trimmed identity, applicable carried advisory → positive state", trimmedHit.state == .affectedFixInstallable && trimmedHit.trimmed)
        let trimmedMiss = state([LTF.cov(key, "osv:Debian:12", "partial"), LTF.cov(key, "cisa-kev")],
                                [LTF.debEntry([LTF.adv(["CVE-2099-0002"], events: [["introduced": "0"], ["fixed": "7:4.0-1"]])])])
        t.check("F3: trimmed identity, nothing applicable → unknown, never 'no known issue'",
                trimmedMiss.state == .unknown && trimmedMiss.reason?.en.contains("too many known issues") == true)
        t.check("F3: trimmed identity with no carried advisory → unknown",
                state([LTF.cov(key, "osv:Debian:12", "partial"), LTF.cov(key, "cisa-kev")]).state == .unknown)
        t.check("F3: mixed ok/partial → positive state",
                state([LTF.cov(key, "osv:Debian:12", "partial"), LTF.cov(key, "cisa-kev", "ok")], [entry]).state == .affectedFixInstallable)
        t.check("F3: partial + a failed source → unknown",
                state([LTF.cov(key, "osv:Debian:12", "partial"), LTF.cov(key, "cisa-kev", "failed")], [entry]).state == .unknown)
        t.check("F3: partial + a missing source → unknown", state([LTF.cov(key, "osv:Debian:12", "partial")], [entry]).state == .unknown)
        t.check("F3: partial + duplicate rows → unknown",
                state([LTF.cov(key, "osv:Debian:12", "partial"), LTF.cov(key, "osv:Debian:12", "partial"), LTF.cov(key, "cisa-kev")], [entry]).state == .unknown)
        t.check("F3: partial + stale → unknown",
                state(LTF.covAll(key, status: "partial", at: LTF.now.addingTimeInterval(-49 * 3600)), [entry]).state == .unknown)
        t.check("origin: another origin → unknown whatever the list says",
                LocalTools.match(LTF.debInstance(originProblem: LocalTools.Text("ppa", "ppa")),
                                 list: LTF.listFor([entry]), now: LTF.now).state == .unknown)
        t.check("list: no current list → unknown", LocalTools.match(LTF.debInstance(), list: nil, now: LTF.now).state == .unknown)
        let unknownScheme = LTF.listFor([LTF.debEntry(scheme: "rpm", [LTF.adv(["CVE-2099-0001"])])])
        t.check("scheme: unsupported version scheme → advisory unknown → state unknown",
                LocalTools.match(LTF.debInstance(), list: unknownScheme, now: LTF.now).state == .unknown)
        let srcVsBin = LTF.debInstance(version: "9:9.9-9", sourceVersion: "7:5.1.6-0+deb12u1")
        t.check("match: ranges compare the SOURCE version, not the binary's",
                LocalTools.match(srcVsBin, list: LTF.listFor([entry]), now: LTF.now).state == .affectedFixInstallable)
        let introducedLater = LTF.listFor([LTF.debEntry([LTF.adv(["CVE-2099-0010"],
            events: [["introduced": "7:5.1.7-0+deb12u1"], ["fixed": "7:5.1.8-0+deb12u1"]], fixed: "7:5.1.8-0+deb12u1")])])
        t.check("match: an installed version below `introduced` is not affected (never 'installed < fixed')",
                LocalTools.match(LTF.debInstance(), list: introducedLater, now: LTF.now).state == .noKnownIssue)
        let withdrawn = LTF.listFor([LTF.debEntry([LTF.adv(["CVE-2099-0001"], withdrawn: true)])])
        t.check("withdrawn advisory clears (no known issue)", LocalTools.match(LTF.debInstance(), list: withdrawn, now: LTF.now).state == .noKnownIssue)
    }

    static func remediationGroup(_ t: Tally) {
        let list = LTF.listFor([LTF.debEntry([LTF.adv(["CVE-2099-0001"])])])
        func m(_ i: LocalTools.Instance, _ l: LocalAdvisory.Document = list) -> LocalTools.ToolReport { LocalTools.match(i, list: l, now: LTF.now) }
        let ok = m(LTF.debInstance())
        t.check("remediation: candidate outside the ranges and ≥ fixed source → installable",
                ok.state == .affectedFixInstallable && ok.action == .apt(["ffmpeg", "libavcodec59"]))
        t.check("remediation: binary candidate built from an OLDER source (binNMU) → not a fix",
                m(LTF.debInstance(candidate: "7:5.1.6-0+deb12u1+b1", candidateSource: "7:5.1.6-0+deb12u1")).state == .affectedNotInstallable)
        t.check("remediation: candidate equal to installed → not installable here",
                m(LTF.debInstance(candidate: "7:5.1.6-0+deb12u1")).state == .affectedNotInstallable)
        t.check("remediation: candidate from another origin → not installable",
                m(LTF.debInstance(pocket: nil)).state == .affectedNotInstallable)
        let esmDoc = LTF.doc(LTF.payload(declared: ["deb:ubuntu:24.04": ["osv:Ubuntu:24.04:LTS", "osv:Ubuntu:Pro:24.04:LTS", "cisa-kev"]],
                                         coverage: LTF.covAll("deb:ubuntu:24.04:ffmpeg", sources: ["osv:Ubuntu:24.04:LTS", "osv:Ubuntu:Pro:24.04:LTS", "cisa-kev"]),
                                         entries: [LTF.debEntry("ffmpeg", release: "24.04", distro: "ubuntu",
            [LTF.adv(["CVE-2099-0003"], events: [["introduced": "0"], ["fixed": "7:6.1.1-3ubuntu5+esm1"]], fixed: "7:6.1.1-3ubuntu5+esm1", pocket: "esm-apps")])]))
        let unattached = m(LTF.debInstance(version: "7:6.1.1-3ubuntu5", release: "24.04", distro: "ubuntu", candidate: "7:6.1.1-3ubuntu5"), esmDoc)
        t.check("remediation: Pro-only fix, system not receiving ESM → not installable (ESM wording)",
                unattached.state == .affectedNotInstallable
                    && unattached.affected.first.map { if case .notInstallable(let w) = $0.fix { return w.en.contains("ESM") }; return false } == true)
        let attached = m(LTF.debInstance(version: "7:6.1.1-3ubuntu5", release: "24.04", distro: "ubuntu",
                                          candidate: "7:6.1.1-3ubuntu5+esm1", pocket: .esmApps), esmDoc)
        t.check("remediation: ESM attached with the candidate → installable", attached.state == .affectedFixInstallable)
        t.check("remediation: package lists too old → fix status unknown (not messaged)",
                m(LTF.debInstance(problem: LocalTools.Text("old", "old"))).state == .affectedNotInstallable
                    && !m(LTF.debInstance(problem: LocalTools.Text("old", "old"))).messageable)
        t.check("remediation: candidate evidence older than 24 h → unknown",
                !m(LTF.debInstance(asOf: LTF.now.addingTimeInterval(-25 * 3600))).hasInstallableFix)
        let noFix = LTF.listFor([LTF.debEntry([LTF.adv(["CVE-2099-0004"], fixed: nil, noFix: "no-dsa")])])
        let nf = m(LTF.debInstance(), noFix)
        t.check("remediation: no fix → affected, no fix (with reason)", nf.state == .affectedNoFix && nf.affected.first?.fix == .noFix(.noDsa))
        t.check("V4: recommended advisory without a fix is not messaged", !nf.messageable)
        let kevNoFix = m(LTF.debInstance(), LTF.listFor([LTF.debEntry([LTF.adv(["CVE-2099-0005"], kev: true, fixed: nil)])]))
        t.check("V4: KEV advisory without a fix is messaged", kevNoFix.messageable && kevNoFix.kevWithoutFix)
        // Homebrew: catalogue must be ≤ 24 h old.
        let brewDoc = LTF.doc(LTF.payload(declared: ["brew:homebrew/core": ["osv:Homebrew"]],
            coverage: [LTF.cov("brew:homebrew/core:ffmpeg:0", "osv:Homebrew")],
            entries: [["identity": ["kind": "brew", "tap": "homebrew/core", "formula": "ffmpeg", "versionScheme": 0], "scheme": "brew",
                       "advisories": [LTF.adv(["CVE-2099-0006"], events: [["introduced": "0"], ["fixed": "7.1.2"]], fixed: "7.1.2")]]]))
        func brew(_ catalogue: String?, _ age: TimeInterval, keg: String = "7.1.1_3") -> LocalTools.ToolReport {
            LocalTools.match(LocalTools.Instance(toolId: "ffmpeg", identity: LocalAdvisory.Identity(kind: .brew, tap: "homebrew/core", formula: "ffmpeg", versionScheme: 0),
                                                 installedVersion: keg, compareVersion: keg, originProblem: nil, binaries: ["ffmpeg"],
                                                 candidates: .brew(version: catalogue, asOf: LTF.now.addingTimeInterval(-age)), usedPath: nil, statusOnly: nil),
                             list: brewDoc, now: LTF.now)
        }
        t.check("brew: fresh catalogue with the fix → installable, `brew upgrade ffmpeg`",
                brew("7.1.2", 3600).state == .affectedFixInstallable && brew("7.1.2", 3600).action == .brew("ffmpeg"))
        t.check("brew: catalogue older than 24 h → fix status unknown", !brew("7.1.2", 25 * 3600).hasInstallableFix)
        t.check("brew: catalogue still on the vulnerable version → not installable", brew("7.1.1_4", 3600).state == .affectedNotInstallable)
        t.check("brew: keg already fixed → no known issue", brew("7.1.2", 3600, keg: "7.1.2").state == .noKnownIssue)
        // Vendor builds (release lines).
        let nodeDoc = LTF.doc(LTF.payload(declared: ["vendor:nodejs.org:node": ["nodejs-security"]],
            coverage: [LTF.cov("vendor:nodejs.org:node:darwin:official", "nodejs-security")],
            entries: [["identity": ["kind": "vendor", "vendor": "nodejs.org", "product": "node", "platform": "darwin", "flavour": "official"],
                       "scheme": "semver",
                       "advisories": [LTF.adv(["CVE-2099-0007"], events: nil, lines: [("20", "20.19.6"), ("22", "22.21.1")],
                                              affected: ["ranges": [["type": "SEMVER", "events": [["introduced": "20.0.0"], ["fixed": "20.19.6"]]],
                                                                    ["type": "SEMVER", "events": [["introduced": "22.0.0"], ["fixed": "22.21.1"]]]]])]]]))
        func node(_ v: String) -> LocalTools.ToolReport {
            LocalTools.match(LocalTools.Instance(toolId: "node", identity: LocalAdvisory.Identity(kind: .vendor, vendor: "nodejs.org", product: "node", platform: "darwin", flavour: "official"),
                                                 installedVersion: v, compareVersion: v, originProblem: nil, binaries: [], candidates: .vendor,
                                                 usedPath: nil, statusOnly: nil), list: nodeDoc, now: LTF.now)
        }
        t.check("vendor: affected line → update from vendor with that line's fix",
                node("22.20.0").action == .vendor(vendor: "nodejs.org", product: "node", minimum: "22.21.1"))
        t.check("vendor: other line fixed → no known issue", node("20.19.6").state == .noKnownIssue)
        let worst = m(LTF.debInstance(), LTF.listFor([LTF.debEntry([LTF.adv(["CVE-2099-0008"], fixed: nil, noFix: "postponed"),
                                                                     LTF.adv(["CVE-2099-0009"], severity: "critical")])]))
        t.check("states: the fixable advisory wins for display; level critical", worst.state == .affectedFixInstallable && worst.level == .critical)
        t.check("states: never 'safe' anywhere in the wording",
                !LocalToolsText.stateText(m(LTF.debInstance(), LTF.listFor([])), lang: "en").lowercased().contains("safe"))
    }
}
