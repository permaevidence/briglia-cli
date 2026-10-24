import Foundation

/// §9.5.10 (security plan v17-v20, §15 items 19-20a): official Node.js
/// provenance (macOS, Linux), the Node release record and maintained lines,
/// the LibreOffice website build (N.N lines, unknownOutside), the new
/// document fields — plus the macOS weekly-message service (§9.5.9).
extension LocalToolsSelftest {
    static func nodeVersionOutput(_ m: FakeMachine, _ path: String, _ v: String) { m.outputs["\(path) --version"] = (0, "v\(v)\n") }

    static func vendorNodeGroup(_ t: Tally) {
        func node(_ m: FakeMachine, _ platform: LocalTools.Platform, env: [String: String] = [:]) -> LocalTools.Resolution? {
            LocalTools.inventory(m.probe(platform, env: env)).first { $0.toolId == "node" }
        }
        func via(_ r: LocalTools.Resolution?) -> String? { if case .present(let i)? = r { return i.vendorVia }; return nil }
        // nvm (macOS).
        let nvm = macMachine()
        let nv = "/home/u/.nvm/versions/node/v24.21.0/bin/node"
        nvm.bins["node"] = nv; nvm.text(nv, "bin"); nodeVersionOutput(nvm, nv, "24.21.0")
        t.check("node: nvm under ~/.nvm → official Node.js, via nvm, darwin identity",
                via(node(nvm, .macOS)) == "nvm" && { if case .present(let i)? = node(nvm, .macOS) { return i.identity.key == "vendor:nodejs.org:node:darwin:official" }; return false }())
        let nvmEnv = macMachine()
        let ne = "/opt/nvm/versions/node/v22.23.4/bin/node"
        nvmEnv.bins["node"] = ne; nvmEnv.text(ne, "bin"); nodeVersionOutput(nvmEnv, ne, "22.23.4")
        nvmEnv.dirs["/opt/nvm"] = []
        t.check("node: nvm under an absolute NVM_DIR → via nvm", via(node(nvmEnv, .macOS, env: ["NVM_DIR": "/opt/nvm"])) == "nvm")
        let mismatch = macMachine()
        mismatch.bins["node"] = nv; mismatch.text(nv, "bin"); nodeVersionOutput(mismatch, nv, "24.20.0")
        if case .unknown? = node(mismatch, .macOS) { t.check("node: nvm path version ≠ node --version → unknown", true) }
        else { t.check("node: nvm path version ≠ node --version → unknown", false) }
        // macOS installer with receipt.
        let pkg = macMachine()
        pkg.bins["node"] = "/usr/local/bin/node"; pkg.text("/usr/local/bin/node", "bin"); nodeVersionOutput(pkg, "/usr/local/bin/node", "24.22.1")
        pkg.files["/var/db/receipts/org.nodejs.node.pkg.plist"] = try! PropertyListSerialization.data(fromPropertyList: ["PackageVersion": "v24.22.1"], format: .xml, options: 0)
        t.check("node: /usr/local/bin/node with a matching nodejs.org receipt → via pkg", via(node(pkg, .macOS)) == "pkg")
        let noReceipt = macMachine()
        noReceipt.bins["node"] = "/usr/local/bin/node"; noReceipt.text("/usr/local/bin/node", "bin"); nodeVersionOutput(noReceipt, "/usr/local/bin/node", "24.22.1")
        noReceipt.text("/usr/local/include/node/node_version.h", "#define NODE_MAJOR_VERSION 24\n#define NODE_MINOR_VERSION 22\n#define NODE_PATCH_VERSION 1\n")
        if case .unknown? = node(noReceipt, .macOS) { t.check("node: /usr/local/bin/node without a receipt → unknown (headers never rescue it)", true) }
        else { t.check("node: /usr/local/bin/node without a receipt → unknown (headers never rescue it)", false) }
        let badReceipt = macMachine()
        badReceipt.bins["node"] = "/usr/local/bin/node"; badReceipt.text("/usr/local/bin/node", "bin"); nodeVersionOutput(badReceipt, "/usr/local/bin/node", "24.22.1")
        badReceipt.files["/var/db/receipts/org.nodejs.node.pkg.plist"] = try! PropertyListSerialization.data(fromPropertyList: ["PackageVersion": "v24.18.0"], format: .xml, options: 0)
        if case .unknown? = node(badReceipt, .macOS) { t.check("node: a receipt for another version → unknown", true) }
        else { t.check("node: a receipt for another version → unknown", false) }
        // Official tarball directory (macOS).
        let tb = macMachine()
        let root = "/home/u/opt/node-v24.21.0-darwin-arm64"
        tb.bins["node"] = root + "/bin/node"; tb.text(root + "/bin/node", "bin"); nodeVersionOutput(tb, root + "/bin/node", "24.21.0")
        tb.text(root + "/include/node/node_version.h", "#define NODE_MAJOR_VERSION 24\n#define NODE_MINOR_VERSION 21\n#define NODE_PATCH_VERSION 0\n")
        t.check("node: an official archive directory with matching header → via tarball:<dir>", via(node(tb, .macOS)) == "tarball:node-v24.21.0-darwin-arm64")
        let conda = macMachine()
        let croot = "/home/u/miniconda3/envs/x/node-v24.21.0-darwin-arm64"
        conda.bins["node"] = croot + "/bin/node"; conda.text(croot + "/bin/node", "bin"); nodeVersionOutput(conda, croot + "/bin/node", "24.21.0")
        conda.text(croot + "/include/node/node_version.h", "#define NODE_MAJOR_VERSION 24\n#define NODE_MINOR_VERSION 21\n#define NODE_PATCH_VERSION 0\n")
        conda.dirs[croot + "/conda-meta"] = []
        if case .unknown? = node(conda, .macOS) { t.check("node: a root with conda-meta → unknown", true) } else { t.check("node: a root with conda-meta → unknown", false) }
        let brew = macMachine()
        brew.bins["node"] = "/opt/homebrew/bin/node"; brew.links["/opt/homebrew/bin/node"] = "/opt/homebrew/Cellar/node/24.21.0/bin/node"
        brew.text("/opt/homebrew/Cellar/node/24.21.0/INSTALL_RECEIPT.json", #"{"source":{"tap":"homebrew/core","versions":{"stable":"24.21.0","version_scheme":0}}}"#)
        if case .present(let i)? = node(brew, .macOS) { t.check("node: Homebrew node → brew identity (weekly message), not vendor", i.identity.kind == .brew) }
        else { t.check("node: Homebrew node → brew identity (weekly message), not vendor", false) }
        vendorNodeLinuxGroup(t)
    }

    static func vendorNodeLinuxGroup(_ t: Tally) {
        func node(_ m: FakeMachine) -> LocalTools.Resolution? { LocalTools.inventory(m.probe(.linux)).first { $0.toolId == "node" } }
        func linux() -> FakeMachine {
            let m = FakeMachine()
            m.text("/etc/os-release", "ID=debian\nVERSION_ID=\"12\"\nVERSION_CODENAME=bookworm\n")
            m.bins = ["dpkg-query": "/usr/bin/dpkg-query", "apt-cache": "/usr/bin/apt-cache"]
            m.outputs["/usr/bin/dpkg-query -W -f ${binary:Package}\t${Version}\t${Source}\t${db:Status-Abbrev}\n"] = (0, "")
            return m
        }
        let nv = "/home/u/.nvm/versions/node/v22.23.2/bin/node"
        let ok = linux()
        ok.bins["node"] = nv; ok.text(nv, "bin"); nodeVersionOutput(ok, nv, "22.23.2")
        ok.outputs["/usr/bin/dpkg-query -S \(nv)"] = (1, "dpkg-query: no path found matching pattern \(nv)\n")
        if case .present(let i)? = node(ok) { t.check("node linux: nvm + positive dpkg 'not found' → official, linux identity", i.identity.key == "vendor:nodejs.org:node:linux:official" && i.vendorVia == "nvm") }
        else { t.check("node linux: nvm + positive dpkg 'not found' → official, linux identity", false) }
        let dpkgFail = linux()
        dpkgFail.bins["node"] = nv; dpkgFail.text(nv, "bin"); nodeVersionOutput(dpkgFail, nv, "22.23.2")
        dpkgFail.outputs["/usr/bin/dpkg-query -S \(nv)"] = (2, "dpkg-query: error: database locked\n")
        if case .unknown? = node(dpkgFail) { t.check("node linux: a failed dpkg ownership probe → unknown (never upstream)", true) }
        else { t.check("node linux: a failed dpkg ownership probe → unknown (never upstream)", false) }
        // Arch-style /usr layout owned by pacman.
        let arch = linux()
        arch.bins["node"] = "/usr/bin/node"; arch.bins["pacman"] = "/usr/bin/pacman"; arch.text("/usr/bin/node", "bin"); nodeVersionOutput(arch, "/usr/bin/node", "24.21.0")
        arch.text("/usr/include/node/node_version.h", "#define NODE_MAJOR_VERSION 24\n#define NODE_MINOR_VERSION 21\n#define NODE_PATCH_VERSION 0\n")
        arch.outputs["/usr/bin/dpkg-query -S /usr/bin/node"] = (1, "dpkg-query: no path found matching pattern /usr/bin/node\n")
        arch.outputs["/usr/bin/env LC_ALL=C /usr/bin/pacman -Qo /usr/bin/node"] = (0, "/usr/bin/node is owned by nodejs-lts-krypton 24.21.0-1\n")
        if case .unknown(_, let why)? = node(arch) { t.check("node linux: Arch /usr/bin/node + headers, pacman-owned → unknown", why.en.contains("packaged by your distribution (pacman)")) }
        else { t.check("node linux: Arch /usr/bin/node + headers, pacman-owned → unknown", false) }
        let unowned = linux()
        unowned.bins["node"] = "/usr/bin/node"; unowned.text("/usr/bin/node", "bin"); nodeVersionOutput(unowned, "/usr/bin/node", "24.21.0")
        unowned.text("/usr/include/node/node_version.h", "#define NODE_MAJOR_VERSION 24\n#define NODE_MINOR_VERSION 21\n#define NODE_PATCH_VERSION 0\n")
        unowned.outputs["/usr/bin/dpkg-query -S /usr/bin/node"] = (1, "dpkg-query: no path found matching pattern /usr/bin/node\n")
        if case .unknown? = node(unowned) { t.check("node linux: /usr layout without ownership evidence → unknown (no layout rule)", true) }
        else { t.check("node linux: /usr layout without ownership evidence → unknown (no layout rule)", false) }
        let rpm = linux()
        let rroot = "/opt/node-v24.21.0-linux-x64"
        rpm.bins["node"] = rroot + "/bin/node"; rpm.bins["rpm"] = "/usr/bin/rpm"; rpm.text(rroot + "/bin/node", "bin"); nodeVersionOutput(rpm, rroot + "/bin/node", "24.21.0")
        rpm.text(rroot + "/include/node/node_version.h", "#define NODE_MAJOR_VERSION 24\n#define NODE_MINOR_VERSION 21\n#define NODE_PATCH_VERSION 0\n")
        rpm.outputs["/usr/bin/dpkg-query -S \(rroot)/bin/node"] = (1, "dpkg-query: no path found matching pattern x\n")
        rpm.outputs["/usr/bin/env LC_ALL=C /usr/bin/rpm -qf \(rroot)/bin/node"] = (0, "nodejs24-24.21.0-1.x86_64\n")
        if case .unknown? = node(rpm) { t.check("node linux: rpm-owned binary in a tarball-looking path → unknown", true) }
        else { t.check("node linux: rpm-owned binary in a tarball-looking path → unknown", false) }
        let tar = linux()
        tar.bins["node"] = rroot + "/bin/node"; tar.text(rroot + "/bin/node", "bin"); nodeVersionOutput(tar, rroot + "/bin/node", "24.21.0")
        tar.text(rroot + "/include/node/node_version.h", "#define NODE_MAJOR_VERSION 24\n#define NODE_MINOR_VERSION 21\n#define NODE_PATCH_VERSION 0\n")
        tar.outputs["/usr/bin/dpkg-query -S \(rroot)/bin/node"] = (1, "dpkg-query: no path found matching pattern x\n")
        if case .present(let i)? = node(tar) { t.check("node linux: unowned official archive directory → via tarball", i.vendorVia == "tarball:node-v24.21.0-linux-x64") }
        else { t.check("node linux: unowned official archive directory → via tarball", false) }
    }

    // MARK: - Node list semantics (release record, maintained lines)

    static func nodeDoc() -> LocalAdvisory.Document {
        let id = "vendor:nodejs.org:node:darwin:official"
        let sources = ["nodejs-security-wg", "nodejs-dist", "nodejs-schedule", "cisa-kev"]
        func sem(_ ids: [String], _ ranges: [[[String: String]]], fixed: [(String, String)], kind: String? = nil) -> [String: Any] {
            var a: [String: Any] = ["ids": ids, "severity": "recommended", "kev": false, "withdrawn": false,
                                    "affected": ["ranges": ranges.map { ["type": "SEMVER", "events": $0] }],
                                    "remediation": ["fixed": fixed.map { ["line": $0.0, "version": $0.1] }, "pocket": NSNull()]]
            if let kind { a["kind"] = kind }
            return a
        }
        let entry: [String: Any] = [
            "identity": ["kind": "vendor", "vendor": "nodejs.org", "product": "node", "platform": "darwin", "flavour": "official"],
            "scheme": "semver", "maintainedLines": ["22", "24", "26"],
            "advisories": [
                sem(["CVE-2099-1001"], [[["introduced": "20.0.0"], ["fixed": "20.20.2"]], [["introduced": "24.0.0"], ["fixed": "24.18.1"]]],
                    fixed: [("20", "20.20.2"), ("24", "24.18.1")]),
                sem(["NODEJS-SR-24-24.22.1"], [[["introduced": "24.0.0"], ["fixed": "24.22.1"]]], fixed: [("24", "24.22.1")], kind: "release"),
            ]]
        return LTF.doc(LTF.payload(declared: ["vendor:nodejs.org:node": sources], coverage: LTF.covAll(id, sources: sources), entries: [entry]))
    }

    static func nodeInstance(_ v: String, via: String = "nvm") -> LocalTools.Instance {
        LocalTools.Instance(vendorVia: via, toolId: "node",
                            identity: LocalAdvisory.Identity(kind: .vendor, vendor: "nodejs.org", product: "node", platform: "darwin", flavour: "official"),
                            installedVersion: v, compareVersion: v, originProblem: nil, binaries: [], candidates: .vendor,
                            usedPath: "/home/u/.nvm/versions/node/v\(v)/bin/node", statusOnly: nil)
    }

    static func nodeListGroup(_ t: Tally) {
        let doc = nodeDoc()
        let r18 = LocalTools.match(nodeInstance("24.18.0"), list: doc, now: LTF.now)
        t.check("node list: 24.18.0 → affected (WG CVE) and also behind the 24.22.1 release; fix target 24.22.1",
                r18.state == .affectedFixInstallable && r18.releases.count == 1 && r18.affected.map(\.primaryId) == ["CVE-2099-1001"]
                && r18.action == .node(via: "nvm", major: "24", minimum: "24.22.1", root: nil))
        let r21 = LocalTools.match(nodeInstance("24.21.0"), list: doc, now: LTF.now)
        t.check("node list: 24.21.0 → behind a security release only (never 'known security problem')",
                r21.state == .behindSecurityRelease && r21.affected.isEmpty && r21.messageable)
        let line = LocalToolsText.line(LocalVuln.Proposal(key: "k", kind: .initial, report: r21), lang: "en")
        t.check("node list: release-only message wording (no 'known security problem', 'To update', the nvm command)",
                line.contains("older than the latest Node.js security release for its line (24.22.1)") && !line.contains("known security problem")
                && line.contains("To update, run: `nvm install 24`") && !line.contains("NODEJS-SR"))
        let r221 = LocalTools.match(nodeInstance("24.22.1"), list: doc, now: LTF.now)
        t.check("node list: 24.22.1 → no known issue (all sources ok, nothing applies)", r221.state == .noKnownIssue)
        let r20 = LocalTools.match(nodeInstance("20.19.5"), list: doc, now: LTF.now)
        t.check("node list: 20.19.5 (EOL line) → still positively affected by a carried advisory", r20.state == .affectedFixInstallable)
        let r20b = LocalTools.match(nodeInstance("20.20.5"), list: doc, now: LTF.now)
        t.check("node list: an EOL line with nothing applicable → unknown 'no longer receives security fixes', never clean",
                r20b.state == .unknown && r20b.reason?.en.contains("no longer receives security fixes") == true)
        let status = LocalToolsText.stateText(r21, lang: "en")
        t.check("node list: Security line says 'older than the latest security release'", status.hasPrefix("older than the latest security release (24.22.1)"))
        let pkgText = LocalToolsText.fixInstruction(.node(via: "pkg", major: "24", minimum: "24.22.1", root: nil), lang: "en") ?? ""
        t.check("node list: installer wording points to nodejs.org/en/download", pkgText.contains("https://nodejs.org/en/download"))
        t.check("node list: a tarball root that is not an official directory name gets no instruction",
                LocalToolsText.fixInstruction(.node(via: "tarball", major: "24", minimum: "24.22.1", root: "x; rm -rf /"), lang: "en") == nil)
        // Parser: the new fields.
        func parses(_ extraAdv: [String: Any] = [:], entryExtra: [String: Any] = [:]) -> Bool {
            var a = LTF.adv(["CVE-2099-1002"]); for (k, v) in extraAdv { a[k] = v }
            var e = LTF.debEntry([a]); for (k, v) in entryExtra { e[k] = v }
            return (try? LocalAdvisory.parseDocument(LTF.payload(coverage: LTF.covAll("deb:debian:12:ffmpeg"), entries: [e]))) != nil
        }
        t.check("parse: kind release / unknownOutside / maintainedLines accepted", parses(["kind": "release", "unknownOutside": true], entryExtra: ["maintainedLines": ["22", "24"]]))
        t.check("parse: malformed unknownOutside / maintainedLines reject the document",
                !parses(["unknownOutside": "yes"]) && !parses(entryExtra: ["maintainedLines": ["24", "24"]]) && !parses(entryExtra: ["maintainedLines": ["v24"]]))
        let futureKind = LTF.doc(LTF.payload(coverage: LTF.covAll("deb:debian:12:ffmpeg"), entries: [LTF.debEntry([LTF.adv(["CVE-2099-1003"]).merging(["kind": "advisory-v2"]) { $1 }])]))
        t.check("parse: an unknown advisory kind is kept as an unknown advisory", futureKind.entries.first?.advisories.first?.kind == .unsupported
                && LocalTools.match(LTF.debInstance(), list: futureKind, now: LTF.now).state == .unknown)
    }

    static func libreOfficeListGroup(_ t: Tally) {
        let id = "vendor:documentfoundation:libreoffice:darwin:official"
        let sources = ["tdf-advisories", "cve-cna", "cisa-kev"]
        func adv(_ cve: String, _ series: String, _ fix: String, outside: Bool) -> [String: Any] {
            var a: [String: Any] = ["ids": [cve], "severity": "recommended", "kev": false, "withdrawn": false,
                                    "affected": ["ranges": [["type": "ECOSYSTEM", "events": [["introduced": series + ".0"], ["fixed": fix]]]]],
                                    "remediation": ["fixed": [["line": series, "version": fix]], "pocket": NSNull()]]
            if outside { a["unknownOutside"] = true }
            return a
        }
        func doc(_ advs: [[String: Any]]) -> LocalAdvisory.Document {
            LTF.doc(LTF.payload(declared: ["vendor:documentfoundation:libreoffice": sources], coverage: LTF.covAll(id, sources: sources),
                                entries: [["identity": ["kind": "vendor", "vendor": "documentfoundation", "product": "libreoffice", "platform": "darwin", "flavour": "official"],
                                           "scheme": "dotted", "advisories": advs]]))
        }
        func inst(_ v: String) -> LocalTools.Instance {
            LocalTools.Instance(vendorVia: "app", toolId: "libreoffice",
                                identity: LocalAdvisory.Identity(kind: .vendor, vendor: "documentfoundation", product: "libreoffice", platform: "darwin", flavour: "official"),
                                installedVersion: v, compareVersion: v, originProblem: nil, binaries: [], candidates: .vendor,
                                usedPath: "/Applications/LibreOffice.app", statusOnly: nil)
        }
        let d = doc([adv("CVE-2099-2001", "26.2", "26.2.5", outside: true)])
        let a = LocalTools.match(inst("26.2.4.2"), list: d, now: LTF.now)
        t.check("libreoffice: 26.2.4.2 in a listed series → affected, fix 26.2.5 from the N.N line, LibreOffice wording",
                a.state == .affectedFixInstallable && a.action == .libreoffice(minimum: "26.2.5")
                && (LocalToolsText.fixInstruction(a.action, lang: "en") ?? "").contains("Help → Check for Updates"))
        let past = LocalTools.match(inst("26.2.5.1"), list: d, now: LTF.now)
        t.check("libreoffice: 26.2.5.1 is past the fix inside the listed series → not affected by it (never 'unlisted series')",
                past.affected.isEmpty && past.unknownAdvisories == 0 && past.state == .noKnownIssue)
        let unlisted = LocalTools.match(inst("26.8.1.1"), list: d, now: LTF.now)
        t.check("libreoffice: an unlisted series with unknownOutside → unknown, never 'no known issue'", unlisted.state == .unknown)
        let un = doc([adv("CVE-2099-2002", "26.2", "26.2.5", outside: false)])
        t.check("libreoffice: defaultStatus unaffected (no unknownOutside) outside the series → no known issue",
                LocalTools.match(inst("26.8.1.1"), list: un, now: LTF.now).state == .noKnownIssue)
        let mixed = doc([adv("CVE-2099-2003", "26.2", "26.2.5", outside: true),
                         ["ids": ["CVE-2099-2004"], "severity": "recommended", "kev": false, "withdrawn": false, "affected": "unknown", "remediation": NSNull(), "noFixReason": "unknown"]])
        let mr = LocalTools.match(inst("26.2.4.2"), list: mixed, now: LTF.now)
        t.check("libreoffice: an unknown advisory never suppresses a separate supported positive", mr.state == .affectedFixInstallable && mr.unknownAdvisories == 1)
    }
}
