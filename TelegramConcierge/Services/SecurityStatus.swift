import Foundation

/// Read-only "Security" status (security auto-update plan, Phase 0): what
/// Briglia's own dependencies are pinned to, and whether the host has OS
/// updates waiting. Never installs, upgrades, deletes or writes anything; the
/// only child processes are read-only queries (`apt-get -s` against the cached
/// lists, `node --version`), each bounded by a timeout, and none of them goes
/// to the network. Homebrew is never launched: its cached catalogue and the
/// Cellar are read as files.
/// Anything it cannot establish is reported as unknown, never as fine. It has
/// no advisory data: "pinned" means pinned, not "known safe".
enum SecurityStatus {

    // MARK: - Model

    enum ComponentState: String, Equatable {
        case pinned        // exact pin, installed copy matches it
        case differs       // Briglia-managed copy differs from this build's pin
        case unpinned      // Briglia installed it without a pin (gap)
        case osRepo        // versions come from the device's package sources
        case userOwned     // the user's / OS's copy; Briglia's version is only a minimum
        case notInstalled
        case off            // AgentMail hold: off until a repair succeeds (§7.8.1 v14)
        case unknownState   // a private copy that does not match its receipt
        case restartPending // selected, not yet running (§7.7)

        var label: String {
            switch self {
            case .pinned: return "pinned"
            case .differs: return "differs from this build's pin"
            case .unpinned: return "not pinned"
            case .osRepo: return "from the device's package sources"
            case .userOwned: return "yours / the OS's"
            case .notInstalled: return "not installed"
            case .off: return "OFF"
            case .unknownState: return "does not match its receipt"
            case .restartPending: return "restart pending"
            }
        }
    }

    struct Component: Equatable {
        let name: String
        let state: ComponentState
        let detail: String
    }

    enum Updates: Equatable {
        case none(source: String, asOf: Date?)
        case pending(source: String, total: Int, security: Int?, asOf: Date?)
        case unknown(source: String, reason: String)
    }

    struct HostReport: Equatable {
        var updates: [Updates]
        var rebootRequired: Bool
        /// Some update information is older than `staleAfter`.
        var stale: Bool
        /// Which sources are stale (for the wording).
        var staleSources: [String] = []
    }

    static let staleAfter: TimeInterval = 7 * 24 * 3600
    static let probeTimeout: TimeInterval = 30

    /// The probes' window on the machine. `live` reads the real system; the
    /// selftest substitutes fakes (and records every command).
    struct Probe {
        var isMacOS: Bool
        var isUbuntuTouch: Bool
        var home: String
        var environment: [String: String]
        var now: () -> Date
        var fileExists: (String) -> Bool
        var readData: (String) -> Data?
        var modificationDate: (String) -> Date?
        /// nil when the directory cannot be read (missing, denied, not a
        /// directory): never confused with a readable empty directory.
        var listDirectory: (String) -> [String]?
        var findBinary: (String) -> String?
        /// (executable, arguments, timeout) → (exit status, merged output).
        var run: (String, [String], TimeInterval) -> (Int32, String)

        static var live: Probe {
            let fm = FileManager.default
            #if os(macOS)
            let mac = true, ut = false
            #else
            let mac = false, ut = AgentServiceSupport.isUbuntuTouch()
            #endif
            return Probe(
                isMacOS: mac, isUbuntuTouch: ut, home: NSHomeDirectory(),
                environment: ProcessInfo.processInfo.environment, now: { Date() },
                fileExists: { fm.fileExists(atPath: $0) },
                readData: { fm.contents(atPath: $0) },
                modificationDate: { (try? fm.attributesOfItem(atPath: $0))?[.modificationDate] as? Date },
                listDirectory: { try? fm.contentsOfDirectory(atPath: $0) },
                findBinary: { PlatformBinary.find($0) },
                run: { exe, args, timeout in
                    let r = UserdataToolchain.run(exe, args, timeout: timeout)
                    return (r.exitCode, r.output)
                })
        }
    }

    // MARK: - Host OS updates

    static func hostReport(_ probe: Probe) -> HostReport {
        dateChecked(rawHostReport(probe), now: probe.now())
    }

    /// Freshness per source: a result without a date is unknown (never
    /// "none"/"pending" on undated evidence), and one older than `staleAfter`
    /// makes the report stale, naming the source.
    static func dateChecked(_ report: HostReport, now: Date) -> HostReport {
        var out = report
        out.updates = report.updates.map { u in
            switch u {
            case .none(let source, let asOf), .pending(let source, _, _, let asOf):
                guard let asOf else { return .unknown(source: source, reason: "the information has no date") }
                if now.timeIntervalSince(asOf) > staleAfter, !out.staleSources.contains(source) { out.staleSources.append(source) }
                return u
            case .unknown:
                return u
            }
        }
        if !out.staleSources.isEmpty { out.stale = true }
        return out
    }

    static func rawHostReport(_ probe: Probe) -> HostReport {
        if probe.isMacOS {
            return HostReport(updates: [macSoftwareUpdate(probe)] + (homebrew(probe).map { [$0] } ?? []),
                              rebootRequired: false, stale: false)
        }
        if probe.isUbuntuTouch {
            return HostReport(updates: [.unknown(source: "Ubuntu Touch",
                                                 reason: "system updates come through the UBports OTA (System Settings → Updates)")],
                              rebootRequired: false, stale: false)
        }
        let reboot = probe.fileExists("/var/run/reboot-required") || probe.fileExists("/run/reboot-required")
        if let apt = probe.findBinary("apt-get") {
            let (updates, stale) = aptUpdates(probe, aptGet: apt)
            return HostReport(updates: [updates], rebootRequired: reboot, stale: stale, staleSources: stale ? ["apt"] : [])
        }
        for manager in ["dnf", "pacman"] where probe.findBinary(manager) != nil {
            return HostReport(updates: [.unknown(source: manager, reason: "pending-update check not supported yet")],
                              rebootRequired: reboot, stale: false)
        }
        return HostReport(updates: [.unknown(source: "OS", reason: "no supported package manager found")],
                          rebootRequired: reboot, stale: false)
    }

    /// `apt-get -s dist-upgrade` against the cached lists: no lock, no network.
    static func aptUpdates(_ probe: Probe, aptGet: String) -> (Updates, Bool) {
        let asOf = newestAptList(probe)
        let stale = asOf.map { probe.now().timeIntervalSince($0) > staleAfter } ?? true
        let script = "LC_ALL=C exec \"$0\" -s -o Debug::NoLocking=true dist-upgrade"
        let (status, output) = probe.run("/bin/sh", ["-c", script, aptGet], probeTimeout)
        guard status == 0 else {
            return (.unknown(source: "apt", reason: status == 124 ? "the check timed out" : "apt-get -s failed (exit \(status))"), false)
        }
        guard asOf != nil else {
            return (.unknown(source: "apt", reason: "no cached package lists (apt update has never run)"), true)
        }
        let counts = parseAptSimulation(output)
        return (counts.total == 0 ? .none(source: "apt", asOf: asOf)
                                  : .pending(source: "apt", total: counts.total, security: counts.security, asOf: asOf), stale)
    }

    static func newestAptList(_ probe: Probe) -> Date? {
        let dir = "/var/lib/apt/lists"
        return (probe.listDirectory(dir) ?? [])
            .filter { $0.hasSuffix("_InRelease") || $0.hasSuffix("_Release") }
            .compactMap { probe.modificationDate(dir + "/" + $0) }
            .max()
    }

    /// Counts `Inst` lines; a line is a security update when its candidate
    /// comes from a -security pocket (Ubuntu `jammy-security`, Debian
    /// `bookworm-security` / `Debian-Security`).
    static func parseAptSimulation(_ text: String) -> (total: Int, security: Int) {
        var total = 0, security = 0
        for line in text.split(separator: "\n") where line.hasPrefix("Inst ") {
            total += 1
            if let open = line.firstIndex(of: "(") {
                let origin = line[open...]
                if origin.contains("-security") || origin.contains("Debian-Security") { security += 1 }
            }
        }
        return (total, security)
    }

    /// Apple's cached result of its own background check; nothing is asked of
    /// the network. Missing keys mean unknown, not "no updates".
    static func macSoftwareUpdate(_ probe: Probe) -> Updates {
        let path = "/Library/Preferences/com.apple.SoftwareUpdate.plist"
        guard let data = probe.readData(path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return .unknown(source: "macOS", reason: "Software Update status unreadable")
        }
        return parseMacSoftwareUpdate(plist)
    }

    static func parseMacSoftwareUpdate(_ plist: [String: Any]) -> Updates {
        let asOf = plist["LastSuccessfulDate"] as? Date
        guard asOf != nil else {
            return .unknown(source: "macOS", reason: "no record of a successful Software Update check")
        }
        if let list = plist["RecommendedUpdates"] as? [Any] {
            return list.isEmpty ? .none(source: "macOS", asOf: asOf)
                                : .pending(source: "macOS", total: list.count, security: nil, asOf: asOf)
        }
        if let count = plist["LastRecommendedUpdatesAvailable"] as? Int {
            return count == 0 ? .none(source: "macOS", asOf: asOf)
                              : .pending(source: "macOS", total: count, security: nil, asOf: asOf)
        }
        return .unknown(source: "macOS", reason: "Software Update record has no update list")
    }

    /// Homebrew formulae whose installed kegs do not include the version in
    /// Homebrew's cached catalogue. brew itself is never run (even
    /// `brew outdated` can download or regenerate its API cache): the
    /// catalogue file and the Cellar are read as files, nothing else. Dated by
    /// the catalogue file. A layout this code does not recognise is unknown.
    /// Casks are not checked. nil when Homebrew is not installed.
    static func homebrew(_ probe: Probe) -> Updates? {
        guard let brew = probe.findBinary("brew") else { return nil }
        let prefix = probe.environment["HOMEBREW_PREFIX"]
            ?? ((brew as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        let cellar = probe.environment["HOMEBREW_CELLAR"] ?? prefix + "/Cellar"
        let cache = probe.environment["HOMEBREW_CACHE"] ?? probe.home + "/Library/Caches/Homebrew"
        let source = "Homebrew formulae"
        guard let path = brewCataloguePath(probe, cache: cache), let data = probe.readData(path) else {
            return .unknown(source: source, reason: "no cached catalogue (run `brew update` once)")
        }
        guard let catalogue = parseBrewCatalogue(data) else {
            return .unknown(source: source, reason: "the cached catalogue's format is not recognised")
        }
        guard let installed = probe.listDirectory(cellar) else {
            return .unknown(source: source, reason: "the Cellar (\(cellar)) cannot be read")
        }
        var differ = 0
        for name in installed where !name.hasPrefix(".") {
            guard let current = catalogue[name] else { continue }   // other taps: not in the catalogue
            guard let listed = probe.listDirectory(cellar + "/" + name) else {
                return .unknown(source: source, reason: "the Cellar entry \(name) cannot be read")
            }
            let kegs = listed.filter { !$0.hasPrefix(".") }
            // A formula of the same name from another tap is not this one.
            if kegs.contains(where: { brewTap(probe, keg: cellar + "/" + name + "/" + $0).map { $0 != "homebrew/core" } ?? false }) { continue }
            if !kegs.contains(current) { differ += 1 }
        }
        let asOf = probe.modificationDate(path)
        return differ == 0 ? .none(source: source, asOf: asOf)
                           : .pending(source: source, total: differ, security: nil, asOf: asOf)
    }

    /// The tap a keg was installed from (its INSTALL_RECEIPT.json), nil when
    /// the receipt does not say.
    static func brewTap(_ probe: Probe, keg: String) -> String? {
        guard let data = probe.readData(keg + "/INSTALL_RECEIPT.json"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let source = json["source"] as? [String: Any] else { return nil }
        return source["tap"] as? String
    }

    /// The newest `api/internal/packages.*.jws.json` (Homebrew 5+), else the
    /// older `api/formula.jws.json`.
    static func brewCataloguePath(_ probe: Probe, cache: String) -> String? {
        let internalDir = cache + "/api/internal"
        let candidates = (probe.listDirectory(internalDir) ?? [])
            .filter { $0.hasPrefix("packages.") && $0.hasSuffix(".jws.json") }
            .map { internalDir + "/" + $0 }
        if let newest = candidates.max(by: { (probe.modificationDate($0) ?? .distantPast) < (probe.modificationDate($1) ?? .distantPast) }) {
            return newest
        }
        let legacy = cache + "/api/formula.jws.json"
        return probe.fileExists(legacy) ? legacy : nil
    }

    /// name → current package version ("3.5.9", or "3.14.9_1" with a
    /// revision) from a JWS catalogue: `{"payload": "<json>"}` whose payload
    /// is either `{"formulae": {name: {stable_version, revision?}}}` or a list
    /// of `{name, versions: {stable}, revision?}`. nil when unrecognised.
    static func parseBrewCatalogue(_ data: Data) -> [String: String]? {
        guard let outer = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payloadText = outer["payload"] as? String, let payloadData = payloadText.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) else { return nil }
        func version(_ stable: Any?, _ revision: Any?) -> String? {
            guard let stable = stable as? String, !stable.isEmpty else { return nil }
            let rev = (revision as? Int) ?? 0
            return rev > 0 ? "\(stable)_\(rev)" : stable
        }
        var out: [String: String] = [:]
        if let dict = payload as? [String: Any], let formulae = dict["formulae"] as? [String: Any] {
            for (name, raw) in formulae {
                guard let f = raw as? [String: Any], let v = version(f["stable_version"], f["revision"]) else { return nil }
                out[name] = v
            }
        } else if let list = payload as? [Any] {
            for raw in list {
                guard let f = raw as? [String: Any], let name = f["name"] as? String,
                      let v = version((f["versions"] as? [String: Any])?["stable"], f["revision"]) else { return nil }
                out[name] = v
            }
        } else {
            return nil
        }
        return out.isEmpty ? nil : out
    }
}
