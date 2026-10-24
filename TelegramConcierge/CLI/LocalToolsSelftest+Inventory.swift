import Foundation

/// A fake machine for the inventory: files, directories, symlinks, PATH
/// binaries and canned command outputs; every command run is recorded.
final class FakeMachine {
    var files: [String: Data] = [:]
    var dirs: [String: [String]] = [:]
    var links: [String: String] = [:]
    var bins: [String: String] = [:]
    /// Raw PATH entries for the renderer's `shutil.which` lookup.
    var pathEntries = ["/usr/local/bin", "/usr/bin"]
    var mtimes: [String: Date] = [:]
    var outputs: [String: (Int32, String)] = [:]
    var commands: [String] = []
    var owned: [String] = ["/home/u/.local/share/briglia/toolchain", "/home/u/.local/share/briglia/node"]

    func text(_ path: String, _ s: String) { files[path] = Data(s.utf8) }

    func probe(_ platform: LocalTools.Platform, env: [String: String] = [:]) -> LocalTools.Probe {
        LocalTools.Probe(
            platform: platform, now: { LTF.now }, environment: env, home: "/home/u",
            readData: { self.files[$0] }, listDirectory: { self.dirs[$0] }, modificationDate: { self.mtimes[$0] },
            resolve: { p in self.links[p] ?? (self.files[p] != nil || self.dirs[p] != nil ? p : nil) },
            findBinary: { self.bins[$0] },
            pathEntries: pathEntries,
            isExecutable: { p in self.files[p] != nil || self.links[p] != nil || self.bins.values.contains(p) },
            run: { exe, args, _ in
                let key = ([exe] + args).joined(separator: " ")
                self.commands.append(key)
                return self.outputs[key] ?? (1, "")
            },
            brigliaOwnedRoots: owned)
    }
}

extension LocalToolsSelftest {
    static let aptPrefix = "/usr/bin/env LC_ALL=C /usr/bin/apt-cache -o Dir::Cache::pkgcache= -o Dir::Cache::srcpkgcache="

    static let globalPolicy = """
    Package files:
     100 /var/lib/dpkg/status
         release a=now
     500 http://deb.debian.org/debian bookworm/main amd64 Packages
         release v=12.7,o=Debian,a=stable,n=bookworm,l=Debian,c=main,b=amd64
         origin deb.debian.org
     500 http://security.debian.org/debian-security bookworm-security/main amd64 Packages
         release v=12,o=Debian,a=stable-security,n=bookworm-security,l=Debian-Security,c=main,b=amd64
         origin security.debian.org
     500 https://ppa.example.org/ffmpeg bookworm/main amd64 Packages
         release o=SomePPA,n=bookworm,c=main
         origin ppa.example.org
     100 http://deb.debian.org/debian bookworm-backports/main amd64 Packages
         release o=Debian,a=stable-backports,n=bookworm-backports,c=main
         origin deb.debian.org
    Pinned packages:
    """

    static func pkgPolicy(_ pkg: String, installed: String, candidate: String, installedFrom: String, candidateFrom: String) -> String {
        var s = "\(pkg):\n  Installed: \(installed)\n  Candidate: \(candidate)\n  Version table:\n"
        if candidate != installed {
            s += "     \(candidate) 500\n        500 \(candidateFrom)\n"
        }
        s += " *** \(installed) 500\n        500 \(installedFrom)\n        100 /var/lib/dpkg/status\n"
        return s
    }

    static func parsersGroup(_ t: Tally) {
        t.check("source: `Source: name (version)` → that name and version (binNMU keeps its source version)",
                LocalTools.normaliseSource(binary: "libavcodec59", version: "7:5.1.6-0+deb12u1+b1", source: "ffmpeg (7:5.1.6-0+deb12u1)")! == ("ffmpeg", "7:5.1.6-0+deb12u1"))
        t.check("source: `Source: name` without a version → the binary's Version",
                LocalTools.normaliseSource(binary: "libfoo1", version: "1.2-3", source: "foo")! == ("foo", "1.2-3"))
        t.check("source: no Source → the binary's own name and Version",
                LocalTools.normaliseSource(binary: "unzip", version: "6.0-28", source: "")! == ("unzip", "6.0-28"))
        let list = LocalTools.parseDpkgList("ffmpeg\t7:5.1.6-0+deb12u1\t\tii \nlibavcodec59:amd64\t7:5.1.6-0+deb12u1\tffmpeg\tii \nold\t1.0\t\trc \n")
        t.check("dpkg list: installed packages parsed, removed-config ignored", list.count == 2 && list["libavcodec59:amd64"]?.sourceName == "ffmpeg")
        t.check("dpkg -S: single owner", LocalTools.parseDpkgSearch("ffmpeg: /usr/bin/ffmpeg\n", path: "/usr/bin/ffmpeg") == "ffmpeg")
        t.check("dpkg -S: two owners → unknown", LocalTools.parseDpkgSearch("a, b: /usr/bin/x\n", path: "/usr/bin/x") == nil)
        t.check("dpkg -S: diversion lines ignored",
                LocalTools.parseDpkgSearch("diversion by foo from: /usr/bin/x\nbar: /usr/bin/x\n", path: "/usr/bin/x") == "bar")
        let g = LocalTools.parseGlobalPolicy(globalPolicy)
        let os = LocalTools.OSRelease(id: "debian", versionId: "12", codename: "bookworm")
        t.check("policy: Debian archive and security are this release's origin",
                LocalTools.originPocket(g["http://deb.debian.org/debian bookworm/main amd64 Packages"], os: os) == .archive
                    && LocalTools.originPocket(g["http://security.debian.org/debian-security bookworm-security/main amd64 Packages"], os: os) == .archive)
        t.check("policy: a PPA is not", LocalTools.originPocket(g["https://ppa.example.org/ffmpeg bookworm/main amd64 Packages"], os: os) == nil)
        t.check("policy: backports are not", LocalTools.originPocket(g["http://deb.debian.org/debian bookworm-backports/main amd64 Packages"], os: os) == nil)
        let u = LocalTools.OSRelease(id: "ubuntu", versionId: "24.04", codename: "noble")
        t.check("policy: Ubuntu ESM apps → esm-apps pocket",
                LocalTools.originPocket(["o": "UbuntuESMApps", "n": "noble-apps-security"], os: u) == .esmApps)
        let p = LocalTools.parsePackagePolicy(pkgPolicy("ffmpeg", installed: "7:5.1.6-0+deb12u1", candidate: "7:5.1.7-0+deb12u1",
                                                        installedFrom: "http://deb.debian.org/debian bookworm/main amd64 Packages",
                                                        candidateFrom: "http://security.debian.org/debian-security bookworm-security/main amd64 Packages"))
        t.check("policy: per-package installed/candidate and version table",
                p["ffmpeg"]?.candidate == "7:5.1.7-0+deb12u1" && p["ffmpeg"]?.versions.count == 2
                    && p["ffmpeg"]?.versions.first(where: { $0.installed })?.files.contains("/var/lib/dpkg/status") == true)
        let recs = LocalTools.parseShowRecords("Package: libavcodec59\nArchitecture: amd64\nVersion: 7:5.1.7-0+deb12u1+b1\nSource: ffmpeg (7:5.1.7-0+deb12u1)\n\nPackage: ffmpeg\nArchitecture: amd64\nVersion: 7:5.1.7-0+deb12u1\n")
        t.check("show: candidate source name and version normalised",
                LocalTools.candidateSource(recs, binary: "libavcodec59:amd64", version: "7:5.1.7-0+deb12u1+b1", nativeArch: "amd64")! == ("ffmpeg", "7:5.1.7-0+deb12u1")
                    && LocalTools.candidateSource(recs, binary: "ffmpeg", version: "7:5.1.7-0+deb12u1", nativeArch: "amd64")! == ("ffmpeg", "7:5.1.7-0+deb12u1"))
        let other = LocalTools.parseShowRecords("Package: libfoo1\nArchitecture: amd64\nVersion: 9.0-1\nSource: unrelated-source (9.0-1)\n")
        t.check("R3: the candidate record keeps ITS source name (another source is visible as such)",
                LocalTools.candidateSource(other, binary: "libfoo1", version: "9.0-1", nativeArch: "amd64")?.0 == "unrelated-source")
        let multi = LocalTools.parseShowRecords("Package: libfoo1\nArchitecture: amd64\nVersion: 2.0-1\nSource: foo (2.0-1)\n\nPackage: libfoo1\nArchitecture: i386\nVersion: 2.0-1\nSource: foo (1.9-1)\n")
        t.check("R3: the architecture selects the record (qualified)",
                LocalTools.candidateSource(multi, binary: "libfoo1:i386", version: "2.0-1", nativeArch: "amd64")?.1 == "1.9-1")
        t.check("R3: unqualified → native architecture's record",
                LocalTools.candidateSource(multi, binary: "libfoo1", version: "2.0-1", nativeArch: "amd64")?.1 == "2.0-1")
        t.check("R3: unknown native architecture and disagreeing records → ambiguous (nil)",
                LocalTools.candidateSource(multi, binary: "libfoo1", version: "2.0-1", nativeArch: nil) == nil)
        let osr = LocalTools.parseOSRelease(Data("ID=debian\nVERSION_ID=\"12\"\nVERSION_CODENAME=bookworm\n".utf8))
        t.check("os-release parsed", osr == os)
        let maps = "7f00-7f01 r-xp 0 08:01 12 /usr/lib/x86_64-linux-gnu/libssl.so.3\n7f02-7f03 r-xp 0 08:01 13 /usr/lib/libxml2.so.2 (deleted)\n"
        t.check("maps: loaded library found; deleted mapping ignored",
                LocalTools.mappedLibrary(maps, prefix: "libssl.so") == "/usr/lib/x86_64-linux-gnu/libssl.so.3" && LocalTools.mappedLibrary(maps, prefix: "libxml2.so") == nil)
    }

    static func debMachine(installedFrom: String = "http://deb.debian.org/debian bookworm/main amd64 Packages") -> FakeMachine {
        let m = FakeMachine()
        m.text("/etc/os-release", "ID=debian\nVERSION_ID=\"12\"\nVERSION_CODENAME=bookworm\n")
        m.bins = ["dpkg-query": "/usr/bin/dpkg-query", "apt-cache": "/usr/bin/apt-cache", "ffmpeg": "/usr/bin/ffmpeg"]
        m.text("/usr/bin/ffmpeg", "ELF")
        m.dirs["/var/lib/apt/lists"] = ["deb.debian.org_debian_dists_bookworm_InRelease",
                                         "security.debian.org_debian-security_dists_bookworm-security_InRelease"]
        m.mtimes["/var/lib/apt/lists/deb.debian.org_debian_dists_bookworm_InRelease"] = LTF.now.addingTimeInterval(-86_400)
        m.mtimes["/var/lib/apt/lists/security.debian.org_debian-security_dists_bookworm-security_InRelease"] = LTF.now.addingTimeInterval(-3600)
        m.outputs["/usr/bin/dpkg-query -W -f ${binary:Package}\t${Version}\t${Source}\t${db:Status-Abbrev}\n"] =
            (0, "ffmpeg\t7:5.1.6-0+deb12u1\t\tii \nlibavcodec59:amd64\t7:5.1.6-0+deb12u1+b1\tffmpeg (7:5.1.6-0+deb12u1)\tii \n")
        m.outputs["/usr/bin/dpkg-query -S /usr/bin/ffmpeg"] = (0, "ffmpeg: /usr/bin/ffmpeg\n")
        m.outputs["\(aptPrefix) policy"] = (0, globalPolicy)
        let cand = "http://security.debian.org/debian-security bookworm-security/main amd64 Packages"
        m.outputs["\(aptPrefix) policy ffmpeg libavcodec59:amd64"] = (0,
            pkgPolicy("ffmpeg", installed: "7:5.1.6-0+deb12u1", candidate: "7:5.1.7-0+deb12u1", installedFrom: installedFrom, candidateFrom: cand)
            + pkgPolicy("libavcodec59:amd64", installed: "7:5.1.6-0+deb12u1+b1", candidate: "7:5.1.7-0+deb12u1", installedFrom: installedFrom, candidateFrom: cand))
        m.outputs["\(aptPrefix) show ffmpeg=7:5.1.7-0+deb12u1 libavcodec59:amd64=7:5.1.7-0+deb12u1"] = (0,
            "Package: ffmpeg\nArchitecture: amd64\nVersion: 7:5.1.7-0+deb12u1\n\nPackage: libavcodec59\nArchitecture: amd64\nVersion: 7:5.1.7-0+deb12u1\nSource: ffmpeg\n")
        m.bins["dpkg"] = "/usr/bin/dpkg"
        m.outputs["/usr/bin/dpkg --print-architecture"] = (0, "amd64\n")
        return m
    }

    static func debInventoryGroup(_ t: Tally) {
        let m = debMachine()
        let inv = LocalTools.inventory(m.probe(.linux))
        guard case .present(let ff)? = inv.first(where: { $0.toolId == "ffmpeg" }) else {
            t.check("deb inventory: ffmpeg present", false, "\(inv.first(where: { $0.toolId == "ffmpeg" }).map { "\($0)" } ?? "none")"); return
        }
        t.check("deb inventory: identity is the SOURCE package of the owning binary", ff.identity.key == "deb:debian:12:ffmpeg")
        t.check("deb inventory: binaries = owner + same-source installed binaries", ff.binaries == ["ffmpeg", "libavcodec59:amd64"])
        t.check("deb inventory: origin from the Debian archive accepted", ff.originProblem == nil)
        if case .deb(let c, _, let problem) = ff.candidates {
            t.check("deb inventory: candidates with normalised source name and version",
                    problem == nil && c.first?.sourceVersion == "7:5.1.7-0+deb12u1" && c.first?.sourceName == "ffmpeg" && c.first?.pocket == .archive
                        && c.count == 2 && c.allSatisfy { $0.sourceName == "ffmpeg" })
        } else { t.check("deb inventory: candidates with normalised source versions", false) }
        t.check("deb inventory: tools not installed → absent (dpkg readable)", inv.first(where: { $0.toolId == "pandoc" }).map { $0 == .absent(toolId: "pandoc") } == true)
        let report = LocalTools.match(.present(ff), list: LTF.listFor([LTF.debEntry([LTF.adv(["CVE-2099-0001"])])]), now: LTF.now)
        t.check("deb inventory → match: affected, fix installable", report.state == .affectedFixInstallable)
        t.check("deb inventory: only read-only commands ran (dpkg-query -W/-S, apt-cache policy/show with caches off)",
                m.commands.allSatisfy { $0.hasPrefix("/usr/bin/dpkg-query -W") || $0.hasPrefix("/usr/bin/dpkg-query -S") || $0.hasPrefix(aptPrefix + " policy") || $0.hasPrefix(aptPrefix + " show") || $0 == "/usr/bin/dpkg --print-architecture" },
                m.commands.joined(separator: " ; "))
        let ppa = debMachine(installedFrom: "https://ppa.example.org/ffmpeg bookworm/main amd64 Packages")
        if case .present(let p)? = LocalTools.inventory(ppa.probe(.linux)).first(where: { $0.toolId == "ffmpeg" }) {
            t.check("deb inventory: installed from a PPA → origin problem → unknown",
                    p.originProblem != nil && LocalTools.match(p, list: LTF.listFor([LTF.debEntry([LTF.adv(["CVE-2099-0001"])])]), now: LTF.now).state == .unknown)
        } else { t.check("deb inventory: installed from a PPA → origin problem → unknown", false) }
        let tc = debMachine()
        tc.bins["ffmpeg"] = "/home/u/.local/bin/ffmpeg"
        tc.text("/home/u/.local/bin/ffmpeg", "#!/bin/sh\nexec /home/u/.local/share/briglia/toolchain/prefix/usr/bin/ffmpeg \"$@\"\n")
        let tcr = LocalTools.inventory(tc.probe(.linux)).first(where: { $0.toolId == "ffmpeg" })
        if case .unknown(_, let why)? = tcr {
            t.check("deb inventory: toolchain wrapper → never a localvuln instance (§9.5.6)", why.en.contains("Briglia's own copy"))
        } else { t.check("deb inventory: toolchain wrapper → never a localvuln instance (§9.5.6)", false, "\(String(describing: tcr))") }
        let br = debMachine()
        br.bins["chromium"] = "/usr/bin/chromium"; br.bins["google-chrome"] = "/usr/bin/google-chrome"
        br.text("/usr/bin/chromium", "ELF"); br.text("/usr/bin/google-chrome", "ELF")
        _ = LocalTools.inventory(br.probe(.linux))
        t.check("R7 (Linux): with chromium and google-chrome on PATH, the renderer's chromium is the one resolved",
                br.commands.contains("/usr/bin/dpkg-query -S /usr/bin/chromium") && !br.commands.contains("/usr/bin/dpkg-query -S /usr/bin/google-chrome"))
        let ut = debMachine()
        if case .present(let u)? = LocalTools.inventory(ut.probe(.ubuntuTouch)).first(where: { $0.toolId == "ffmpeg" }) {
            t.check("deb inventory: Ubuntu Touch rootfs packages are status-only (OTA)", u.statusOnly != nil
                    && !LocalTools.match(u, list: LTF.listFor([LTF.debEntry([LTF.adv(["CVE-2099-0001"])])]), now: LTF.now).messageable)
        } else { t.check("deb inventory: Ubuntu Touch rootfs packages are status-only (OTA)", false) }
        func candProblem(_ m: FakeMachine) -> LocalTools.Text?? {
            guard case .present(let o)? = LocalTools.inventory(m.probe(.linux)).first(where: { $0.toolId == "ffmpeg" }),
                  case .deb(let c, _, _) = o.candidates, let first = c.first else { return nil }
            return .some(first.indexProblem)
        }
        let old = debMachine()
        old.mtimes["/var/lib/apt/lists/security.debian.org_debian-security_dists_bookworm-security_InRelease"] = LTF.now.addingTimeInterval(-9 * 86_400)
        old.mtimes["/var/lib/apt/lists/deb.debian.org_debian_dists_bookworm_InRelease"] = LTF.now.addingTimeInterval(-60)
        t.check("N2: the candidate's own index is 9 days old while an unrelated index is fresh → candidate unusable",
                candProblem(old)??.en.contains("9 days") == true)
        let edge = debMachine()
        edge.mtimes["/var/lib/apt/lists/security.debian.org_debian-security_dists_bookworm-security_InRelease"] = LTF.now.addingTimeInterval(-(7 * 86_400 + 23 * 3600))
        t.check("N2: 7 days 23 hours is stale (no truncation to whole days)", candProblem(edge)??.en.contains("7 days") == true)
        let fresh = debMachine()
        t.check("N2: a fresh candidate index → no problem", candProblem(fresh).map { $0 == nil } == true)
        t.check("N2: list-file name mangling",
                LocalTools.releaseFileName(forPackageFile: "http://security.debian.org/debian-security bookworm-security/main amd64 Packages")
                    == "security.debian.org_debian-security_dists_bookworm-security"
                    && LocalTools.releaseFileName(forPackageFile: "/var/lib/dpkg/status") == nil)
        let broken = debMachine()
        broken.outputs.removeValue(forKey: "/usr/bin/dpkg-query -W -f ${binary:Package}\t${Version}\t${Source}\t${db:Status-Abbrev}\n")
        t.check("deb inventory: unreadable package database → every tool unknown (never absent)",
                LocalTools.inventory(broken.probe(.linux)).allSatisfy { if case .unknown = $0 { return true }; return false })
        let other = debMachine()
        other.text("/etc/os-release", "ID=fedora\nVERSION_ID=40\nVERSION_CODENAME=x\n")
        t.check("deb inventory: an unsupported distribution → unknown",
                LocalTools.inventory(other.probe(.linux)).allSatisfy { if case .unknown = $0 { return true }; return false })
    }

    static func macMachine() -> FakeMachine {
        let m = FakeMachine()
        let cellar = "/opt/homebrew/Cellar"
        m.bins = ["brew": "/opt/homebrew/bin/brew", "ffmpeg": "/opt/homebrew/bin/ffmpeg", "git": "/usr/bin/git"]
        m.links["/opt/homebrew/bin/ffmpeg"] = "\(cellar)/ffmpeg/7.1.1_3/bin/ffmpeg"
        m.links["/usr/bin/git"] = "/usr/bin/git"
        m.dirs[cellar] = ["ffmpeg"]
        m.dirs["\(cellar)/ffmpeg"] = ["7.1.1_3", "7.1.2"]
        m.text("\(cellar)/ffmpeg/7.1.1_3/INSTALL_RECEIPT.json", #"{"source":{"tap":"homebrew/core","versions":{"stable":"7.1.1","version_scheme":0}}}"#)
        m.text("\(cellar)/ffmpeg/7.1.2/INSTALL_RECEIPT.json", #"{"source":{"tap":"homebrew/core","versions":{"stable":"7.1.2","version_scheme":0}}}"#)
        let cache = "/home/u/Library/Caches/Homebrew"
        m.dirs["\(cache)/api/internal"] = ["packages.arm64_tahoe.jws.json"]
        let payload = #"{"formulae":{"ffmpeg":{"stable_version":"7.1.2"}}}"#
        let jws = try! JSONSerialization.data(withJSONObject: ["payload": payload])
        m.files["\(cache)/api/internal/packages.arm64_tahoe.jws.json"] = jws
        m.mtimes["\(cache)/api/internal/packages.arm64_tahoe.jws.json"] = LTF.now.addingTimeInterval(-3600)
        return m
    }

    static func macInventoryGroup(_ t: Tally) {
        let m = macMachine()
        let inv = LocalTools.inventory(m.probe(.macOS))
        guard case .present(let ff)? = inv.first(where: { $0.toolId == "ffmpeg" }) else {
            t.check("mac inventory: ffmpeg keg present", false); return
        }
        t.check("mac inventory: identity tap + formula + version_scheme", ff.identity.key == "brew:homebrew/core:ffmpeg:0")
        t.check("mac inventory: the keg the used executable lives in (older 7.1.1_3 linked while 7.1.2 is installed)",
                ff.installedVersion == "7.1.1_3")
        let brewDoc = LTF.doc(LTF.payload(declared: ["brew:homebrew/core": ["osv:Homebrew"]],
            coverage: [LTF.cov("brew:homebrew/core:ffmpeg:0", "osv:Homebrew")],
            entries: [["identity": ["kind": "brew", "tap": "homebrew/core", "formula": "ffmpeg", "versionScheme": 0], "scheme": "brew",
                       "advisories": [LTF.adv(["CVE-2099-0006"], events: [["introduced": "0"], ["fixed": "7.1.2"]], fixed: "7.1.2")]]]))
        t.check("mac inventory → match: the linked older keg is affected though a fixed keg is installed",
                LocalTools.match(ff, list: brewDoc, now: LTF.now).state == .affectedFixInstallable)
        t.check("mac inventory: brew itself is never run", !m.commands.contains { $0.contains("brew") })
        if case .unknown(_, let why)? = inv.first(where: { $0.toolId == "git" }) {
            t.check("mac inventory: Apple's /usr/bin tool → unknown (macOS's)", why.en.contains("macOS"))
        } else { t.check("mac inventory: Apple's /usr/bin tool → unknown (macOS's)", false) }
        let head = macMachine()
        head.links["/opt/homebrew/bin/ffmpeg"] = "/opt/homebrew/Cellar/ffmpeg/HEAD-1a2b3c/bin/ffmpeg"
        head.text("/opt/homebrew/Cellar/ffmpeg/HEAD-1a2b3c/INSTALL_RECEIPT.json", #"{"source":{"tap":"homebrew/core","versions":{"head":"HEAD"}}}"#)
        if case .present(let h)? = LocalTools.inventory(head.probe(.macOS)).first(where: { $0.toolId == "ffmpeg" }) {
            t.check("mac inventory: HEAD keg → origin problem → unknown", h.originProblem != nil && LocalTools.match(h, list: brewDoc, now: LTF.now).state == .unknown)
        } else { t.check("mac inventory: HEAD keg → origin problem → unknown", false) }
        let tap = macMachine()
        tap.text("/opt/homebrew/Cellar/ffmpeg/7.1.1_3/INSTALL_RECEIPT.json", #"{"source":{"tap":"someone/tap","versions":{"stable":"7.1.1","version_scheme":0}}}"#)
        if case .present(let x)? = LocalTools.inventory(tap.probe(.macOS)).first(where: { $0.toolId == "ffmpeg" }) {
            t.check("mac inventory: formula from another tap → unknown", x.originProblem?.en.contains("another Homebrew tap") == true)
        } else { t.check("mac inventory: formula from another tap → unknown", false) }
        let app = macMachine()
        app.files["/Applications/Google Chrome.app/Contents/Info.plist"] = try! PropertyListSerialization.data(
            fromPropertyList: ["CFBundleShortVersionString": "130.0.6723.58"], format: .xml, options: 0)
        app.text("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "MachO")
        if case .present(let c)? = LocalTools.inventory(app.probe(.macOS)).first(where: { $0.toolId == "chrome" }) {
            t.check("mac inventory: Chrome.app → vendor identity with its bundle version",
                    c.identity.key == "vendor:google:chrome:darwin:stable" && c.installedVersion == "130.0.6723.58")
        } else { t.check("mac inventory: Chrome.app → vendor identity with its bundle version", false) }
        // R7: the browser in the PDF renderer's order.
        func addApp(_ m: FakeMachine, _ name: String, exe: String, version: String?, executable: Bool = true) {
            if let version {
                m.files["/Applications/\(name).app/Contents/Info.plist"] = try! PropertyListSerialization.data(
                    fromPropertyList: ["CFBundleShortVersionString": version], format: .xml, options: 0)
            }
            if executable { m.text("/Applications/\(name).app/Contents/MacOS/\(exe)", "MachO") }
        }
        let both = macMachine()
        addApp(both, "Google Chrome", exe: "Google Chrome", version: "130.0.6723.58")
        addApp(both, "Chromium", exe: "Chromium", version: "131.0.6778.1")
        both.files["/Applications/Google Chrome.app/Contents/Info.plist"] = try! PropertyListSerialization.data(
            fromPropertyList: ["CFBundleShortVersionString": "130.0.6723.58"], format: .xml, options: 0)
        both.files["/Applications/Chromium.app/Contents/Info.plist"] = try! PropertyListSerialization.data(
            fromPropertyList: ["CFBundleShortVersionString": "131.0.6778.1"], format: .xml, options: 0)
        if case .present(let c)? = LocalTools.inventory(both.probe(.macOS)).first(where: { $0.toolId == "chrome" }) {
            t.check("R7: with Chromium.app and Chrome.app both installed, the renderer's choice (Chromium) is checked",
                    c.identity.key == "vendor:chromium.org:chromium:darwin:official")
        } else { t.check("R7: with Chromium.app and Chrome.app both installed, the renderer's choice (Chromium) is checked", false) }
        let pathFirst = macMachine()
        addApp(pathFirst, "Google Chrome", exe: "Google Chrome", version: "130.0.6723.58")
        pathFirst.bins["google-chrome"] = "/usr/local/bin/google-chrome"
        pathFirst.links["/usr/local/bin/google-chrome"] = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        addApp(pathFirst, "Microsoft Edge", exe: "Microsoft Edge", version: "131.0.2903.1")
        if case .present(let c)? = LocalTools.inventory(pathFirst.probe(.macOS)).first(where: { $0.toolId == "chrome" }) {
            t.check("R7: a PATH browser comes before the app bundles (and maps to its bundle)", c.identity.key == "vendor:google:chrome:darwin:stable")
        } else { t.check("R7: a PATH browser comes before the app bundles (and maps to its bundle)", false) }
        let edgeOnly = macMachine()
        addApp(edgeOnly, "Microsoft Edge", exe: "Microsoft Edge", version: "131.0.2903.1")
        if case .present(let c)? = LocalTools.inventory(edgeOnly.probe(.macOS)).first(where: { $0.toolId == "chrome" }) {
            t.check("R7: Edge alone is the renderer's fallback and is checked", c.identity.key == "vendor:microsoft:edge:darwin:stable")
        } else { t.check("R7: Edge alone is the renderer's fallback and is checked", false) }
        let leftover = macMachine()
        addApp(leftover, "Chromium", exe: "Chromium", version: "131.0.6778.1", executable: false)
        addApp(leftover, "Google Chrome", exe: "Google Chrome", version: "130.0.6723.58")
        if case .present(let c)? = LocalTools.inventory(leftover.probe(.macOS)).first(where: { $0.toolId == "chrome" }) {
            t.check("R7: a leftover Chromium plist without its executable is skipped (renderer's predicate)",
                    c.identity.key == "vendor:google:chrome:darwin:stable")
        } else { t.check("R7: a leftover Chromium plist without its executable is skipped (renderer's predicate)", false) }
        let noPlist = macMachine()
        addApp(noPlist, "Chromium", exe: "Chromium", version: nil)
        addApp(noPlist, "Google Chrome", exe: "Google Chrome", version: "130.0.6723.58")
        if case .unknown? = LocalTools.inventory(noPlist.probe(.macOS)).first(where: { $0.toolId == "chrome" }) {
            t.check("R7: the selected Chromium with unreadable metadata → unknown, no fall-through", true)
        } else { t.check("R7: the selected Chromium with unreadable metadata → unknown, no fall-through", false) }
        let emptyPath = macMachine()
        emptyPath.pathEntries = ["", "/usr/bin"]
        addApp(emptyPath, "Google Chrome", exe: "Google Chrome", version: "130.0.6723.58")
        if case .unknown(_, let why)? = LocalTools.inventory(emptyPath.probe(.macOS)).first(where: { $0.toolId == "chrome" }) {
            t.check("R7: an empty PATH entry (renderer's cwd) → unknown", why.en.contains("empty entry"))
        } else { t.check("R7: an empty PATH entry (renderer's cwd) → unknown", false) }
        let unreadable = macMachine()
        unreadable.dirs.removeValue(forKey: "/opt/homebrew/Cellar")
        t.check("mac inventory: unreadable Cellar → missing tools unknown, not absent",
                LocalTools.inventory(unreadable.probe(.macOS)).first(where: { $0.toolId == "pandoc" }).map { if case .unknown = $0 { return true }; return false } == true)
    }
}
