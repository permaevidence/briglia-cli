import Foundation

/// Briglia's own dependencies as installed on this machine, classified
/// against what this build pins (full inventory: security/dependencies.json
/// in the repository). Pure classifiers + one live collector; read-only.
extension SecurityStatus {

    // MARK: - Classifiers (pure; exercised by the selftest)

    static func classifyPlaywright(_ shape: ManagedPlaywright.EntryShape, bundledHash: String?) -> Component {
        switch shape {
        case .managed(let token):
            let hash = ManagedPlaywright.Layout.lockfileHash(ofToken: token)
            if let bundledHash, bundledHash != hash {
                return Component(name: "Playwright MCP", state: .differs,
                                 detail: "installed lockfile \(hash) differs from this build's \(bundledHash) (switched at the next successful start)")
            }
            return Component(name: "Playwright MCP", state: .pinned, detail: "lockfile \(hash), sha512 per package, installed without scripts")
        case .legacyAuto:
            return Component(name: "Playwright MCP", state: .unpinned, detail: "legacy `npx @playwright/mcp@latest` entry (replaced by the pinned install at the next successful start)")
        case .userAuthored, .managedEdited:
            return Component(name: "Playwright MCP", state: .userOwned, detail: "your own mcp.json entry — not managed by Briglia")
        case .absent, .disabled:
            return Component(name: "Playwright MCP", state: .notInstalled, detail: shape == .disabled ? "disabled in mcp.json" : "not registered")
        }
    }

    static func classifyAgentMail(brokerInstalled: Bool, installed: String?, pinned: String) -> Component {
        guard brokerInstalled else {
            return Component(name: "AgentMail CLI", state: .notInstalled, detail: "not installed")
        }
        if installed == pinned {
            return Component(name: "AgentMail CLI", state: .pinned, detail: "\(pinned), SHA-256 compiled in")
        }
        return Component(name: "AgentMail CLI", state: .differs,
                         detail: "\(installed ?? "unknown version") installed, this build pins \(pinned) — `briglia agentmail upgrade` moves it")
    }

    /// `resolved` is `path` with symlinks resolved; `managedRoot` is the
    /// directory Briglia's Node installer extracts to.
    static func classifyNode(path: String?, resolved: String?, managedRoot: String, version: String?) -> Component {
        guard let path else {
            return Component(name: "Node.js", state: .notInstalled, detail: "not found")
        }
        let v = version.map { " \($0)" } ?? ""
        let target = resolved ?? path
        if target == managedRoot || target.hasPrefix(managedRoot.hasSuffix("/") ? managedRoot : managedRoot + "/") {
            return Component(name: "Node.js", state: .unpinned,
                             detail: "Briglia-downloaded copy\(v) (latest LTS at install time, never updated since)")
        }
        return Component(name: "Node.js", state: .userOwned, detail: "\(path)\(v); Briglia only needs ≥ \(ManagedPlaywright.minimumNodeMajor) and never replaces it")
    }

    static func classifyGws(path: String?, home: String) -> Component? {
        guard let path else { return nil }
        if path == home + "/.local/bin/gws" {
            return Component(name: "gws", state: .unpinned, detail: "~/.local/bin/gws — installed as GitHub `latest`, no pin")
        }
        return Component(name: "gws", state: .userOwned, detail: path)
    }

    static func classifyWhatsApp(deployed: Bool) -> Component? {
        deployed ? Component(name: "WhatsApp bridge", state: .unpinned, detail: "npm version ranges, no lockfile") : nil
    }

    static func classifyToolchain(manifest: [String: String]) -> Component? {
        guard !manifest.isEmpty else { return nil }
        return Component(name: "userdata toolchain", state: .osRepo,
                         detail: "\(manifest.count) packages from this device's apt sources; updated only by `briglia toolchain upgrade`")
    }

    // MARK: - Live collector

    /// `probeVersions: false` avoids every child process (for /status).
    static func components(probeVersions: Bool) -> [Component] {
        var out: [Component] = []
        let layout = ManagedPlaywright.Layout()
        let entry = MCPRegistry.loadConfigsFromDisk().first { $0.name == ManagedPlaywright.serverName }
        out.append(classifyPlaywright(ManagedPlaywright.shape(of: entry, layout: layout),
                                      bundledHash: (try? ManagedPlaywright.Manifests.bundled())?.lockfileHash))
        out.append(classifyAgentMail(brokerInstalled: AgentMailService.agentMailBrokerInstalled(),
                                     installed: AgentMailService.installedCLIVersion(),
                                     pinned: AgentMailService.pinnedVersion))
        let node = NodeInstaller.detectNode()
        var version: String? = nil
        if probeVersions, let node {
            let r = UserdataToolchain.run(node, ["--version"], timeout: 10)
            let text = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if r.exitCode == 0, text.hasPrefix("v"), text.count < 32 { version = text }
        }
        out.append(classifyNode(path: node, resolved: node.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                                managedRoot: NodeInstaller.installRoot.resolvingSymlinksInPath().path, version: version))
        let gwsPath = ["/opt/homebrew/bin/gws", "/usr/local/bin/gws", NSHomeDirectory() + "/.cargo/bin/gws",
                       NSHomeDirectory() + "/.local/bin/gws", "/usr/bin/gws"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        if let gws = classifyGws(path: gwsPath, home: NSHomeDirectory()) { out.append(gws) }
        let bridge = StoragePaths.dataRoot.appendingPathComponent("whatsapp-bridge/node_modules").path
        if let wa = classifyWhatsApp(deployed: FileManager.default.fileExists(atPath: bridge)) { out.append(wa) }
        if let tc = classifyToolchain(manifest: UserdataToolchain.loadManifest()) { out.append(tc) }
        return out
    }

    // MARK: - Rendering

    static func age(_ date: Date?, now: Date) -> String {
        guard let date else { return "age unknown" }
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 3600 { return "\(max(1, s / 60)) min ago" }
        if s < 2 * 86_400 { return "\(s / 3600) h ago" }
        return "\(s / 86_400) days ago"
    }

    static func describe(_ u: Updates, now: Date) -> String {
        switch u {
        case .none(let source, let asOf):
            return "\(source): no pending updates (as of \(age(asOf, now: now)))"
        case .pending(let source, let total, let security, let asOf):
            let sec = security.map { ", \($0) security" } ?? ""
            return "\(source): \(total) update\(total == 1 ? "" : "s") pending\(sec) (as of \(age(asOf, now: now)))"
        case .unknown(let source, let reason):
            return "\(source): unknown — \(reason)"
        }
    }

    /// Needs attention: a Briglia copy behind its pin, pending OS security
    /// updates, a needed restart, stale or unknown OS data. Never "up to
    /// date": this status has no advisory data.
    static func needsAttention(_ components: [Component], _ host: HostReport?) -> [String] {
        var reasons: [String] = []
        let behind = components.filter { $0.state == .differs }.map(\.name)
        if !behind.isEmpty { reasons.append("behind this build's pin: \(behind.joined(separator: ", "))") }
        guard let host else { return reasons }
        for u in host.updates {
            if case .pending(let source, _, let security, _) = u, (security ?? 1) > 0 {
                reasons.append(security == nil ? "\(source) updates pending" : "\(source) security updates pending")
            }
            if case .unknown(let source, _) = u { reasons.append("\(source) status unknown") }
        }
        if host.stale { reasons.append("package lists more than 7 days old") }
        if host.rebootRequired { reasons.append("restart required by OS updates") }
        return reasons
    }

    /// One line for /status, the dashboard and doctor's header.
    static func summaryLine(components: [Component], host: HostReport?, now: Date) -> String {
        let unpinned = components.filter { $0.state == .unpinned }.map(\.name)
        let pinned = components.filter { $0.state == .pinned }.count
        var parts = ["Briglia: \(pinned) pinned" + (unpinned.isEmpty ? "" : ", unpinned: \(unpinned.joined(separator: ", "))")]
        if let host {
            parts += host.updates.map { describe($0, now: now) }
        } else {
            parts.append("OS updates: checking… (ask again in a moment, or run `briglia doctor`)")
        }
        let reasons = needsAttention(components, host)
        let head = reasons.isEmpty ? "🛡️ Security" : "🛡️ Security — needs attention (\(reasons.joined(separator: "; ")))"
        return head + ": " + parts.joined(separator: " · ")
    }

    static func doctorLines(components: [Component], host: HostReport, now: Date) -> [String] {
        var lines = [summaryLine(components: components, host: host, now: now)]
        for c in components { lines.append("\(c.name): \(c.state.label) — \(c.detail)") }
        for u in host.updates { lines.append(describe(u, now: now)) }
        if host.stale { lines.append("cached package lists are more than 7 days old: the counts above may be out of date") }
        if host.rebootRequired { lines.append("the OS reports that a restart is required to finish installed updates") }
        lines.append("read-only: nothing was installed or changed; no advisory data here — the repository's daily watch tracks advisories")
        return lines
    }
}

/// /status cache: the host check runs at most once per `ttl`, off the
/// caller's thread; /status itself never waits for a child process.
final class SecurityStatusCache: @unchecked Sendable {
    static let shared = SecurityStatusCache()
    static let ttl: TimeInterval = 6 * 3600

    private let lock = NSLock()
    private var host: (at: Date, report: SecurityStatus.HostReport)?
    private var running = false

    /// The cached host report, starting a background refresh when absent or
    /// older than `ttl`.
    func hostReport(now: Date = Date(), probe: @escaping () -> SecurityStatus.Probe = { .live }) -> SecurityStatus.HostReport? {
        lock.lock()
        let cached = host
        let start = !running && (cached == nil || now.timeIntervalSince(cached!.at) > Self.ttl)
        if start { running = true }
        lock.unlock()
        if start {
            DispatchQueue.global(qos: .utility).async {
                let report = SecurityStatus.hostReport(probe())
                self.lock.lock()
                self.host = (Date(), report)
                self.running = false
                self.lock.unlock()
            }
        }
        return cached?.report
    }

    func statusLine() -> String {
        SecurityStatus.summaryLine(components: SecurityStatus.components(probeVersions: false),
                                   host: hostReport(), now: Date())
    }
}
