import Foundation

/// Read-only "Security" status (security auto-update plan, Phase 0): what
/// Briglia's own dependencies are pinned to, and whether the host has OS
/// updates waiting. Never installs, upgrades, deletes or writes anything; the
/// only child processes are read-only queries (`apt-get -s`, `brew outdated`,
/// `node --version`), each bounded by a timeout, and none of them goes to the
/// network (`brew` runs with auto-update off and is skipped when Homebrew has
/// never downloaded its metadata; `apt-get -s` reads the cached lists).
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

        var label: String {
            switch self {
            case .pinned: return "pinned"
            case .differs: return "behind this build's pin"
            case .unpinned: return "not pinned"
            case .osRepo: return "from the device's package sources"
            case .userOwned: return "yours / the OS's"
            case .notInstalled: return "not installed"
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
        /// The cached package metadata is older than `staleAfter`.
        var stale: Bool
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
        var listDirectory: (String) -> [String]
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
                listDirectory: { (try? fm.contentsOfDirectory(atPath: $0)) ?? [] },
                findBinary: { PlatformBinary.find($0) },
                run: { exe, args, timeout in
                    let r = UserdataToolchain.run(exe, args, timeout: timeout)
                    return (r.exitCode, r.output)
                })
        }
    }

    // MARK: - Host OS updates

    static func hostReport(_ probe: Probe) -> HostReport {
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
            return HostReport(updates: [updates], rebootRequired: reboot, stale: stale)
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
            return (.unknown(source: "apt", reason: status == 124 ? "the check timed out" : "apt-get -s failed (exit \(status))"), stale)
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
        return probe.listDirectory(dir)
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

    /// `brew outdated` with auto-update off, only when Homebrew already has
    /// its formula metadata cached (otherwise brew would download it).
    /// Verified 2026-10-23: with every proxy pointed at a dead port it still
    /// answers, i.e. it makes no network request.
    /// nil when Homebrew is not installed (nothing to report).
    static func homebrew(_ probe: Probe) -> Updates? {
        guard let brew = probe.findBinary("brew") else { return nil }
        let cache = probe.environment["HOMEBREW_CACHE"] ?? probe.home + "/Library/Caches/Homebrew"
        // Homebrew's API cache layout varies by version (formula.jws.json,
        // formula_names.txt, internal/…): any entry means metadata exists;
        // the newest entry dates it.
        let apiDir = cache + "/api"
        let entries = probe.listDirectory(apiDir)
        guard !entries.isEmpty else {
            return .unknown(source: "Homebrew", reason: "metadata never downloaded (run `brew update` once)")
        }
        let asOf = entries.compactMap { probe.modificationDate(apiDir + "/" + $0) }.max()
        let script = "HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ENV_HINTS=1 "
            + "exec \"$0\" outdated --json=v2 2>/dev/null"
        let (status, output) = probe.run("/bin/sh", ["-c", script, brew], probeTimeout)
        guard status == 0, let count = parseBrewOutdated(output) else {
            return .unknown(source: "Homebrew", reason: status == 124 ? "the check timed out" : "brew outdated failed")
        }
        return count == 0 ? .none(source: "Homebrew", asOf: asOf)
                          : .pending(source: "Homebrew", total: count, security: nil, asOf: asOf)
    }

    static func parseBrewOutdated(_ text: String) -> Int? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let formulae = json["formulae"] as? [Any], let casks = json["casks"] as? [Any] else { return nil }
        return formulae.count + casks.count
    }
}
