import ArgumentParser
import Foundation

/// Read-only Security status (auto-update plan, Phase 0): parsers, the host
/// probes against a fake machine (which also records every command, so a
/// mutating command fails the run), the component classifiers, the summary
/// wording (never "up to date", unknown is never fine) and the /status cache.
/// No network, no storage, no real child processes.
struct SecurityStatusSelftest: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__security-status-selftest",
        abstract: "Internal: verify the read-only Security status (doctor, /status).",
        shouldDisplay: false
    )

    final class Tally {
        var total = 0, failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            total += 1
            print("\(ok ? "✔" : "✖") \(label)\(ok || detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }
    }

    func run() throws {
        let t = Tally()
        Self.aptParsing(t)
        Self.aptProbe(t)
        Self.brewAndMac(t)
        Self.hostDispatch(t)
        Self.classifiers(t)
        Self.wording(t)
        Self.binaryAndMenu(t)
        Self.cache(t)
        print(t.failures == 0 ? "\nALL \(t.total) SECURITY STATUS CHECKS PASSED" : "\n\(t.failures) of \(t.total) FAILED")
        if t.failures > 0 { throw ExitCode(1) }
    }

    // MARK: - Fake machine

    final class Recorder: @unchecked Sendable {
        var commands: [(String, [String])] = []
    }

    static let now = Date(timeIntervalSince1970: 1_792_700_000)

    static func fake(mac: Bool = false, ut: Bool = false, files: [String: Data] = [:], dirs: [String: [String]] = [:],
                     mtimes: [String: Date] = [:], binaries: [String: String] = [:],
                     result: @escaping ([String]) -> (Int32, String) = { _ in (0, "") }, recorder: Recorder) -> SecurityStatus.Probe {
        SecurityStatus.Probe(
            isMacOS: mac, isUbuntuTouch: ut, home: "/home/u", environment: [:], now: { now },
            fileExists: { files[$0] != nil || dirs[$0] != nil }, readData: { files[$0] },
            modificationDate: { mtimes[$0] }, listDirectory: { dirs[$0] }, findBinary: { binaries[$0] },
            run: { exe, args, _ in recorder.commands.append((exe, args)); return result(args) })
    }

    static let ubuntuSim = """
        NOTE: This is only a simulation!
        Inst libssl3 [3.0.2-0ubuntu1.15] (3.0.2-0ubuntu1.18 Ubuntu:22.04/jammy-updates, Ubuntu:22.04/jammy-security [amd64])
        Inst tzdata [2024a-0ubuntu0.22.04] (2025b-0ubuntu0.22.04 Ubuntu:22.04/jammy-updates [all])
        Conf libssl3 (3.0.2-0ubuntu1.18 Ubuntu:22.04/jammy-updates, Ubuntu:22.04/jammy-security [amd64])
        """
    static let debianSim = """
        Inst openssl [3.0.11-1~deb12u2] (3.0.13-1~deb12u1 Debian-Security:12/stable-security [arm64])
        Inst curl [7.88.1-10+deb12u5] (7.88.1-10+deb12u8 Debian:12.7/stable [arm64])
        Inst libcurl4 [7.88.1-10+deb12u5] (7.88.1-10+deb12u8 Debian:12.7/stable, Debian-Security:12/stable-security [arm64])
        """

    // MARK: - Checks

    static func aptParsing(_ t: Tally) {
        let u = SecurityStatus.parseAptSimulation(ubuntuSim)
        t.check("apt: Ubuntu simulation → 2 updates, 1 security (Conf lines ignored)", u.total == 2 && u.security == 1, "\(u)")
        let d = SecurityStatus.parseAptSimulation(debianSim)
        t.check("apt: Debian simulation → 3 updates, 2 from Debian-Security", d.total == 3 && d.security == 2, "\(d)")
        let none = SecurityStatus.parseAptSimulation("Reading package lists...\n0 upgraded, 0 newly installed\n")
        t.check("apt: nothing to install → 0/0", none.total == 0 && none.security == 0)
        let name = SecurityStatus.parseAptSimulation("Inst foo-security-tools [1] (2 Ubuntu:22.04/jammy-updates [all])")
        t.check("apt: '-security' in a PACKAGE name is not a security origin", name.total == 1 && name.security == 0, "\(name)")
    }

    static func aptMachine(listsAge: TimeInterval?, status: Int32, output: String, rec: Recorder) -> SecurityStatus.Probe {
        var dirs: [String: [String]] = [:], mtimes: [String: Date] = [:]
        if let listsAge {
            dirs["/var/lib/apt/lists"] = ["archive.ubuntu.com_ubuntu_dists_jammy_InRelease", "lock", "partial"]
            mtimes["/var/lib/apt/lists/archive.ubuntu.com_ubuntu_dists_jammy_InRelease"] = now.addingTimeInterval(-listsAge)
        }
        return fake(dirs: dirs, mtimes: mtimes, binaries: ["apt-get": "/usr/bin/apt-get"],
                    result: { _ in (status, output) }, recorder: rec)
    }

    static func aptProbe(_ t: Tally) {
        let rec = Recorder()
        let fresh = SecurityStatus.hostReport(aptMachine(listsAge: 3600, status: 0, output: ubuntuSim, rec: rec))
        t.check("apt probe: fresh lists → pending 2 (1 security), not stale",
                fresh.updates == [.pending(source: "apt", total: 2, security: 1, asOf: now.addingTimeInterval(-3600))] && !fresh.stale,
                "\(fresh)")
        let stale = SecurityStatus.hostReport(aptMachine(listsAge: 8 * 86_400, status: 0, output: "", rec: rec))
        t.check("apt probe: lists 8 days old → stale, and the summary needs attention",
                stale.stale && SecurityStatus.summaryLine(components: [], host: stale, now: now).contains("more than 7 days old"))
        let noLists = SecurityStatus.hostReport(aptMachine(listsAge: nil, status: 0, output: "", rec: rec))
        t.check("apt probe: no cached lists → unknown, never 'no pending updates'",
                { if case .unknown = noLists.updates.first { return true }; return false }(), "\(noLists)")
        let failed = SecurityStatus.hostReport(aptMachine(listsAge: 60, status: 100, output: "E: broken", rec: rec))
        let timeout = SecurityStatus.hostReport(aptMachine(listsAge: 60, status: 124, output: "", rec: rec))
        t.check("apt probe: failure / timeout → unknown with the reason",
                failed.updates == [.unknown(source: "apt", reason: "apt-get -s failed (exit 100)")]
                && timeout.updates == [.unknown(source: "apt", reason: "the check timed out")])
        t.check("apt probe: only read-only simulation commands were run (\(rec.commands.count))",
                rec.commands.count == 5 && rec.commands.allSatisfy(readOnly), "\(rec.commands)")
    }

    /// The only commands the probes may ever run.
    static func readOnly(_ cmd: (String, [String])) -> Bool {
        guard cmd.0 == "/bin/sh", cmd.1.count == 3, cmd.1[0] == "-c" else { return false }
        let script = cmd.1[1]
        return script == "LC_ALL=C exec \"$0\" -s -o Debug::NoLocking=true dist-upgrade" && cmd.1[2] == "/usr/bin/apt-get"
    }

    static func jws(_ payload: Any) -> Data {
        let inner = String(data: try! JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
        return try! JSONSerialization.data(withJSONObject: ["payload": inner, "signatures": []])
    }

    static func brewAndMac(_ t: Tally) {
        let modern = jws(["metadata": [:], "formulae": ["openssl@3": ["stable_version": "3.5.9"], "python@3.14": ["stable_version": "3.14.9", "revision": 1],
                                                       "ffmpeg": ["stable_version": "8.1"], "bun": ["stable_version": "1.4.4"]]])
        t.check("brew catalogue: Homebrew 5+ internal packages → name → version (with revision)",
                SecurityStatus.parseBrewCatalogue(modern) == ["openssl@3": "3.5.9", "python@3.14": "3.14.9_1", "ffmpeg": "8.1", "bun": "1.4.4"])
        let legacy = jws([["name": "jq", "versions": ["stable": "1.8.1"], "revision": 0]])
        t.check("brew catalogue: legacy formula.jws.json list", SecurityStatus.parseBrewCatalogue(legacy) == ["jq": "1.8.1"])
        t.check("brew catalogue: corrupt / truncated / unknown shape / a row without a version → nil",
                SecurityStatus.parseBrewCatalogue(Data("{".utf8)) == nil
                && SecurityStatus.parseBrewCatalogue(modern.prefix(modern.count / 2)) == nil
                && SecurityStatus.parseBrewCatalogue(jws(["casks": [:]])) == nil
                && SecurityStatus.parseBrewCatalogue(jws(["formulae": ["x": ["desc": "no version"]]])) == nil)
        let rec = Recorder()
        let api = "/home/u/Library/Caches/Homebrew/api"
        let brew = ["brew": "/opt/homebrew/bin/brew"]
        let cellar = ["/opt/homebrew/Cellar": ["openssl@3", "python@3.14", "ffmpeg", "sometap-tool", "bun", ".DS_Store"],
                      "/opt/homebrew/Cellar/openssl@3": ["3.5.9", "3.6.4"], "/opt/homebrew/Cellar/python@3.14": ["3.14.9"],
                      "/opt/homebrew/Cellar/ffmpeg": ["8.1"], "/opt/homebrew/Cellar/sometap-tool": ["1.0"], "/opt/homebrew/Cellar/bun": ["1.3.11"]]
        // bun shares a core formula's name but came from another tap: not compared.
        let receipts = ["/opt/homebrew/Cellar/bun/1.3.11/INSTALL_RECEIPT.json": Data(#"{"source":{"tap":"oven-sh/bun"}}"#.utf8),
                        "/opt/homebrew/Cellar/python@3.14/3.14.9/INSTALL_RECEIPT.json": Data(#"{"source":{"tap":"homebrew/core"}}"#.utf8)]
        func mac(_ files: [String: Data], _ internalNames: [String], mtime: Date?) -> SecurityStatus.Probe {
            let files = files.merging(receipts) { a, _ in a }
            var dirs = cellar
            if !internalNames.isEmpty { dirs[api + "/internal"] = internalNames }
            var m: [String: Date] = [:]
            if let mtime { for n in internalNames { m[api + "/internal/" + n] = mtime }; m[api + "/formula.jws.json"] = mtime }
            return fake(mac: true, files: files, dirs: dirs, mtimes: m, binaries: brew, recorder: rec)
        }
        t.check("brew: not installed → omitted (nothing to report)", SecurityStatus.homebrew(fake(mac: true, recorder: rec)) == nil)
        t.check("brew: no cached catalogue → unknown",
                SecurityStatus.homebrew(mac([:], [], mtime: nil)) == .unknown(source: "Homebrew formulae", reason: "no cached catalogue (run `brew update` once)"))
        let pkg = api + "/internal/packages.arm64_x.jws.json"
        t.check("brew: an unrelated file in the API directory is not a catalogue → unknown",
                { if case .unknown = SecurityStatus.homebrew(mac([api + "/internal/sentinel.txt": Data()], ["sentinel.txt"], mtime: now)) { return true }; return false }())
        t.check("brew: python@3.14 keg 3.14.9 vs catalogue 3.14.9_1 → 1 differs; same-name formula from another tap, other-tap formula and dotfiles ignored; dated by the catalogue",
                SecurityStatus.homebrew(mac([pkg: modern], ["packages.arm64_x.jws.json"], mtime: now.addingTimeInterval(-60)))
                == .pending(source: "Homebrew formulae", total: 1, security: nil, asOf: now.addingTimeInterval(-60)))
        t.check("brew: corrupt catalogue → unknown (format not recognised)",
                SecurityStatus.homebrew(mac([pkg: Data("{".utf8)], ["packages.arm64_x.jws.json"], mtime: now))
                == .unknown(source: "Homebrew formulae", reason: "the cached catalogue's format is not recognised"))
        t.check("brew: legacy layout read when no internal catalogue exists",
                SecurityStatus.homebrew(mac([api + "/formula.jws.json": legacy], [], mtime: now)) == .none(source: "Homebrew formulae", asOf: now))
        func cellarCase(_ dirsOverride: [String: [String]?]) -> SecurityStatus.Updates? {
            var dirs: [String: [String]] = cellar
            for (k, v) in dirsOverride { dirs[k] = v }
            dirs[api + "/internal"] = ["packages.arm64_x.jws.json"]
            let files = [pkg: modern].merging(receipts) { a, _ in a }
            return SecurityStatus.homebrew(fake(mac: true, files: files, dirs: dirs, mtimes: [pkg: now], binaries: brew, recorder: rec))
        }
        let unknownCellar = SecurityStatus.Updates.unknown(source: "Homebrew formulae", reason: "the Cellar (/opt/homebrew/Cellar) cannot be read")
        t.check("brew: a missing or unreadable Cellar → unknown, never 'no pending updates'",
                cellarCase(["/opt/homebrew/Cellar": nil]) == unknownCellar)
        t.check("brew: an unreadable formula directory → unknown",
                cellarCase(["/opt/homebrew/Cellar/python@3.14": nil]) == .unknown(source: "Homebrew formulae", reason: "the Cellar entry python@3.14 cannot be read"))
        t.check("brew: a genuinely empty, readable Cellar → none (control)",
                cellarCase(["/opt/homebrew/Cellar": []]) == .none(source: "Homebrew formulae", asOf: now))
        let unknownHost = SecurityStatus.HostReport(updates: [unknownCellar], rebootRequired: false, stale: false)
        t.check("brew: the unknown Cellar reaches the line and both menu languages",
                SecurityStatus.summaryLine(components: [], host: unknownHost, now: now).contains("Homebrew formulae status unknown")
                && ((SecurityStatus.menuPayload(components: [], host: unknownHost, binary: nil)["attention_it"] as? [String]) ?? []).contains("stato Homebrew formulae sconosciuto"))
        t.check("brew: no child process was ever started (brew is never run)", rec.commands.isEmpty, "\(rec.commands)")

        let old = now.addingTimeInterval(-30 * 86_400)
        let staleMac = SecurityStatus.hostReport(fake(mac: true, files: ["/Library/Preferences/com.apple.SoftwareUpdate.plist":
            try! PropertyListSerialization.data(fromPropertyList: ["LastSuccessfulDate": old, "RecommendedUpdates": []], format: .binary, options: 0)],
            recorder: rec))
        t.check("freshness: a 30-day-old macOS record → stale, named, and the line/menu need attention",
                staleMac.stale && staleMac.staleSources == ["macOS"]
                && SecurityStatus.summaryLine(components: [], host: staleMac, now: now).contains("update information more than 7 days old (macOS)")
                && ((SecurityStatus.menuPayload(components: [], host: staleMac, binary: nil)["attention_it"] as? [String])?.first?.contains("più vecchie di 7 giorni") ?? false),
                "\(staleMac)")
        let staleBrew = SecurityStatus.hostReport(mac([pkg: modern, "/Library/Preferences/com.apple.SoftwareUpdate.plist":
            try! PropertyListSerialization.data(fromPropertyList: ["LastSuccessfulDate": now, "RecommendedUpdates": []], format: .binary, options: 0)],
            ["packages.arm64_x.jws.json"], mtime: old))
        t.check("freshness: a 30-day-old Homebrew catalogue → stale (Homebrew formulae)", staleBrew.staleSources == ["Homebrew formulae"], "\(staleBrew)")
        let undated = SecurityStatus.dateChecked(SecurityStatus.HostReport(updates: [.none(source: "Homebrew formulae", asOf: nil)], rebootRequired: false, stale: false), now: now)
        t.check("freshness: an undated result is unknown, never 'none'",
                undated.updates == [.unknown(source: "Homebrew formulae", reason: "the information has no date")])

        let when = Date(timeIntervalSince1970: 1_792_690_000)
        t.check("macOS: no successful-check record → unknown (missing keys are not 'none')",
                { if case .unknown = SecurityStatus.parseMacSoftwareUpdate(["RecommendedUpdates": []]) { return true }; return false }())
        t.check("macOS: empty list → none; two entries → pending 2; count fallback",
                SecurityStatus.parseMacSoftwareUpdate(["LastSuccessfulDate": when, "RecommendedUpdates": []]) == .none(source: "macOS", asOf: when)
                && SecurityStatus.parseMacSoftwareUpdate(["LastSuccessfulDate": when, "RecommendedUpdates": [[:], [:]]]) == .pending(source: "macOS", total: 2, security: nil, asOf: when)
                && SecurityStatus.parseMacSoftwareUpdate(["LastSuccessfulDate": when, "LastRecommendedUpdatesAvailable": 0]) == .none(source: "macOS", asOf: when))
        t.check("macOS: unreadable preferences → unknown",
                { if case .unknown = SecurityStatus.macSoftwareUpdate(fake(mac: true, recorder: rec)) { return true }; return false }())
    }

    static func hostDispatch(_ t: Tally) {
        let rec = Recorder()
        let ut = SecurityStatus.hostReport(fake(ut: true, binaries: ["apt-get": "/usr/bin/apt-get"], recorder: rec))
        t.check("Ubuntu Touch: unknown (OTA), apt never run on the read-only rootfs",
                { if case .unknown(source: "Ubuntu Touch", _) = ut.updates.first { return true }; return false }() && rec.commands.isEmpty)
        let dnf = SecurityStatus.hostReport(fake(files: ["/run/reboot-required": Data()], binaries: ["dnf": "/usr/bin/dnf"], recorder: rec))
        t.check("dnf: unknown (not supported yet); reboot-required file is reported",
                dnf.updates == [.unknown(source: "dnf", reason: "pending-update check not supported yet")] && dnf.rebootRequired)
        t.check("restart required → summary needs attention",
                SecurityStatus.summaryLine(components: [], host: dnf, now: now).contains("restart required"))
    }

    static func classifiers(_ t: Tally) {
        let h = "0123456789abcdef"
        t.check("playwright: managed install of this build's lockfile → pinned",
                SecurityStatus.classifyPlaywright(.managed(token: h), bundledHash: h).state == .pinned)
        t.check("playwright: older lockfile → differs; legacy npx@latest → unpinned; own entry → userOwned; absent → notInstalled",
                SecurityStatus.classifyPlaywright(.managed(token: h + "-r00000000"), bundledHash: "fedcba9876543210").state == .differs
                && SecurityStatus.classifyPlaywright(.legacyAuto, bundledHash: h).state == .unpinned
                && SecurityStatus.classifyPlaywright(.userAuthored, bundledHash: h).state == .userOwned
                && SecurityStatus.classifyPlaywright(.absent, bundledHash: h).state == .notInstalled)
        t.check("agentmail: pinned / behind / absent",
                SecurityStatus.classifyAgentMail(brokerInstalled: true, installed: "1.3.0", pinned: "1.3.0").state == .pinned
                && SecurityStatus.classifyAgentMail(brokerInstalled: true, installed: "legacy", pinned: "1.3.0").state == .differs
                && SecurityStatus.classifyAgentMail(brokerInstalled: false, installed: nil, pinned: "1.3.0").state == .notInstalled)
        let root = "/home/u/.local/node"
        t.check("node: a link into Briglia's ~/.local/node → unpinned; a look-alike sibling directory is NOT Briglia's",
                SecurityStatus.classifyNode(path: "/home/u/.local/bin/node", resolved: root + "/bin/node", managedRoot: root, version: "v22.1.0").state == .unpinned
                && SecurityStatus.classifyNode(path: "/x/node", resolved: "/home/u/.local/node-evil/bin/node", managedRoot: root, version: nil).state == .userOwned
                && SecurityStatus.classifyNode(path: nil, resolved: nil, managedRoot: root, version: nil).state == .notInstalled)
        // gws and the WhatsApp bridge were removed (2026-10-24): never a
        // Briglia component any more (read-only listing, no version probes).
        let names = SecurityStatus.components(probeVersions: false).map(\.name)
        t.check("retired gws / WhatsApp bridge: never listed as Briglia components",
                !names.contains("gws") && !names.contains("WhatsApp bridge"), names.joined(separator: ", "))
        t.check("toolchain: reported only when present",
                SecurityStatus.classifyToolchain(manifest: [:]) == nil
                && SecurityStatus.classifyToolchain(manifest: ["ffmpeg": "7:6.1"])?.state == .osRepo)
    }

    static func wording(_ t: Tally) {
        let pinned = [SecurityStatus.Component(name: "Playwright MCP", state: .pinned, detail: "")]
        let clean = SecurityStatus.HostReport(updates: [.none(source: "apt", asOf: now.addingTimeInterval(-7200))], rebootRequired: false, stale: false)
        let line = SecurityStatus.summaryLine(components: pinned, host: clean, now: now)
        t.check("clean host + pinned: no 'needs attention', no 'up to date' claim",
                !line.contains("needs attention") && !line.lowercased().contains("up to date") && line.contains("2 h ago"), line)
        let behind = [SecurityStatus.Component(name: "AgentMail CLI", state: .differs, detail: "")]
        t.check("a copy behind its pin → needs attention, named",
                SecurityStatus.summaryLine(components: behind, host: clean, now: now).contains("needs attention (differs from this build's pin: AgentMail CLI)"))
        let sec = SecurityStatus.HostReport(updates: [.pending(source: "apt", total: 4, security: 1, asOf: now)], rebootRequired: false, stale: false)
        let nonSec = SecurityStatus.HostReport(updates: [.pending(source: "apt", total: 4, security: 0, asOf: now)], rebootRequired: false, stale: false)
        t.check("apt security updates → attention; non-security only → no attention",
                SecurityStatus.summaryLine(components: [], host: sec, now: now).contains("apt security updates pending")
                && !SecurityStatus.summaryLine(components: [], host: nonSec, now: now).contains("needs attention"))
        let unknown = SecurityStatus.HostReport(updates: [.unknown(source: "dnf", reason: "x")], rebootRequired: false, stale: false)
        t.check("unknown OS status → attention (unknown is never fine)",
                SecurityStatus.summaryLine(components: [], host: unknown, now: now).contains("dnf status unknown"))
        let unpinned = [SecurityStatus.Component(name: "Node.js", state: .unpinned, detail: ""),
                        SecurityStatus.Component(name: "gws", state: .unpinned, detail: "")]
        t.check("unpinned components are named in the line",
                SecurityStatus.summaryLine(components: unpinned, host: clean, now: now).contains("unpinned: Node.js, gws"))
        t.check("no host data yet → 'checking', not a verdict",
                SecurityStatus.summaryLine(components: pinned, host: nil, now: now).contains("checking"))
        let doctor = SecurityStatus.doctorLines(components: pinned, host: clean, now: now)
        t.check("doctor lines: summary first, one per component, read-only footer",
                doctor.count == 4 && doctor[0].hasPrefix("🛡️ Security") && doctor.last?.hasPrefix("read-only") == true, "\(doctor)")
    }

    static func binaryAndMenu(_ t: Tally) {
        let domain = "briglia-cli|https://example.test/releases/"
        func trust(_ json: String) -> Data { Data(json.utf8) }
        let good = SecurityStatus.parseTrust(trust(#"{"schema":2,"domains":{"briglia-cli|https://example.test/releases/":121,"staging|x":900}}"#), domain: domain)
        t.check("trust: this channel's floor is read; another channel's never counts",
                good.floor == 121 && !good.unreadable, "\(good)")
        t.check("trust: absent file → no floor, not unreadable; other-domain-only → no floor",
                SecurityStatus.parseTrust(nil, domain: domain) == (nil, false)
                && SecurityStatus.parseTrust(trust(#"{"schema":2,"domains":{"staging|x":900}}"#), domain: domain) == (nil, false))
        t.check("trust: v1 / garbage / non-positive → unreadable (reported, never trusted)",
                SecurityStatus.parseTrust(trust(#"{"schema":1,"sequence":5}"#), domain: domain).unreadable
                && SecurityStatus.parseTrust(trust("{"), domain: domain).unreadable
                && SecurityStatus.parseTrust(trust(#"{"schema":2,"domains":{"a":0}}"#), domain: domain).unreadable)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sec-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let asDir = dir.appendingPathComponent("release_trust.json")
        try? FileManager.default.createDirectory(at: asDir, withIntermediateDirectories: true)
        let missing = SecurityStatus.readTrust(path: dir.appendingPathComponent("absent.json").path, domain: domain)
        let notAFile = SecurityStatus.readTrust(path: asDir.path, domain: domain)
        try? FileManager.default.removeItem(at: dir)
        t.check("trust: nothing at the path → none recorded; a directory there → unreadable (not 'none recorded')",
                missing == (nil, false) && notAFile == (nil, true), "\(missing) \(notAFile)")

        let clean = SecurityStatus.HostReport(updates: [.none(source: "apt", asOf: now)], rebootRequired: false, stale: false)
        let same = SecurityStatus.BinaryInfo(version: "0.2.60", sequence: 120, floor: 120, trustUnreadable: false)
        let newer = SecurityStatus.BinaryInfo(version: "0.2.60", sequence: 120, floor: 123, trustUnreadable: false)
        let broken = SecurityStatus.BinaryInfo(version: "0.2.60", sequence: 120, floor: nil, trustUnreadable: true)
        let line = SecurityStatus.summaryLine(components: [], host: clean, now: now, binary: same)
        t.check("binary: the line names version and release sequence; floor == own sequence is not attention",
                line.contains("Briglia 0.2.60 (release 120)") && !line.contains("needs attention"), line)
        t.check("binary: a floor above this binary's sequence (newer release already seen) → attention naming /upgrade",
                SecurityStatus.summaryLine(components: [], host: clean, now: now, binary: newer).contains("needs attention (a newer signed Briglia release was seen (sequence 123) — send /upgrade)"))
        t.check("binary: an unreadable trust record → attention",
                SecurityStatus.summaryLine(components: [], host: clean, now: now, binary: broken).contains("release-trust record is unreadable"))
        let doctor = SecurityStatus.doctorLines(components: [], host: clean, now: now, binary: SecurityStatus.BinaryInfo(version: "0.2.60", sequence: 120, floor: nil, trustUnreadable: false))
        t.check("doctor: the binary line says no floor is recorded yet and that the last-check time is not recorded",
                doctor.count == 4 && doctor[1].contains("none recorded yet") && doctor[1].contains("not recorded"), "\(doctor)")

        let behind = [SecurityStatus.Component(name: "AgentMail CLI", state: .differs, detail: "")]
        let sec = SecurityStatus.HostReport(updates: [.pending(source: "apt", total: 3, security: 2, asOf: now), .unknown(source: "Homebrew", reason: "x")],
                                            rebootRequired: true, stale: true)
        let reasons = SecurityStatus.attentionReasons(behind, sec, binary: newer)
        t.check("reasons: every reason has an Italian twin and the English list matches the summary",
                reasons.count == 6 && reasons.allSatisfy { !$0.it.isEmpty && $0.it != $0.en }
                && SecurityStatus.needsAttention(behind, sec, binary: newer) == reasons.map(\.en), "\(reasons)")
        let menuChecking = SecurityStatus.menuPayload(components: [], host: nil, binary: same)
        let menuClean = SecurityStatus.menuPayload(components: [], host: clean, binary: same)
        let menuBad = SecurityStatus.menuPayload(components: behind, host: sec, binary: newer)
        t.check("menu: no host data yet → checking with no reasons; clean → no reasons, not checking",
                menuChecking["checking"] as? Bool == true && (menuChecking["attention"] as? [String])?.isEmpty == true
                && menuClean["checking"] as? Bool == false && (menuClean["attention"] as? [String])?.isEmpty == true)
        t.check("menu: attention reasons in both languages, same count",
                (menuBad["attention"] as? [String])?.count == 6 && (menuBad["attention_it"] as? [String])?.count == 6
                && (menuBad["attention_it"] as? [String])?.first?.contains("invia /upgrade") == true)
        let js = QuickSetupPreflight.pageDirectory().flatMap { try? String(contentsOf: $0.appendingPathComponent("menu.js"), encoding: .utf8) } ?? ""
        t.check("menu page: renders the note on both dashboards, never says 'up to date'",
                js.components(separatedBy: "securityNote(),").count == 3 && js.contains("function securityNote()")
                && !js.contains("Security: up to date"), js.isEmpty ? "menu.js not found next to the binary" : "")
    }

    static func cache(_ t: Tally) {
        let cache = SecurityStatusCache()
        let rec = Recorder()
        let calls = Recorder()
        let probe: () -> SecurityStatus.Probe = {
            calls.commands.append(("probe", []))
            return aptMachine(listsAge: 60, status: 0, output: "", rec: rec)
        }
        let first = cache.hostReport(now: now, probe: probe)
        var waited = 0
        while cache.hostReport(now: now, probe: probe) == nil && waited < 200 { usleep(10_000); waited += 1 }
        t.check("cache: first call returns nil at once and refreshes in the background", first == nil && waited < 200)
        _ = cache.hostReport(now: Date(), probe: probe)
        usleep(50_000)
        t.check("cache: within the TTL the host check is not repeated", calls.commands.count == 1, "\(calls.commands.count) probes")
        _ = cache.hostReport(now: Date().addingTimeInterval(SecurityStatusCache.ttl + 60), probe: probe)
        waited = 0
        while calls.commands.count < 2 && waited < 200 { usleep(10_000); waited += 1 }
        t.check("cache: after the TTL it refreshes again", calls.commands.count == 2)
    }
}
