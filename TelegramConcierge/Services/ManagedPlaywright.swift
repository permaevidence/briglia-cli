import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Glibc)
import Glibc
#endif

/// Lockfile-managed Playwright MCP installation (security plan §H4.4,
/// Release C).
///
/// Until v0.2.6 the auto-registered `playwright` server was
/// `npx @playwright/mcp@latest`: every daemon start re-resolved "latest"
/// against the npm registry and ran whatever it served, unaudited. The
/// managed install replaces that with a tree pinned by the committed
/// `Resources/MCPBundles/playwright/package-lock.json` (exact versions and
/// SHA-512 integrity for every package), installed once per lockfile into
/// an immutable versioned directory and referenced from `mcp.json` by an
/// atomic config write:
///
///     ~/.local/share/briglia/mcp/
///         playwright-install.lock          flock, held for the whole bootstrap
///         playwright-bootstrap.json        last outcome (doctor)
///         playwright.staging-<uuid>/       build in progress (orphans removed)
///         playwright-<lockfileHash>/       immutable, verified install
///             .briglia-complete            marker, written last, holds the hash
///             package.json, package-lock.json, node_modules/…
///         playwright.corrupt-<uuid>/       quarantined failed verification
///
/// Transaction (one installation lock, `npm ci` inside it):
///   1. lock → remove orphan staging/corrupt directories;
///   2. an existing `playwright-<hash>` is VERIFIED (marker + `initialize`
///      handshake) and reused, or quarantined and rebuilt — never referenced
///      while unverified;
///   3. staging: manifests copied in, `npm ci --ignore-scripts` under a
///      bounded timeout in its own process group (terminated, reaped and
///      verified gone on timeout), executable present, handshake answers,
///      completion marker written last;
///   4. publish: every file and directory fsynced bottom-up, `rename` to the
///      immutable name, parent directory fsynced;
///   5. the switch is ONE atomic write of `mcp.json` that changes only the
///      playwright entry (`MCPRegistry.updateManagedPlaywrightEntry`). Until
///      it lands, the previous entry keeps working; if it never lands, nothing
///      was lost.
/// Valid immutable installations are never auto-deleted: an external edit
/// of `mcp.json` (the agent through file tools, or a human) may reference any
/// of them at any time. `doctor` lists unreferenced versions.
///
/// Version TOKENS: a directory is `playwright-<lockfileHash>` or, when a
/// replacement had to be built while the plain name was still referenced,
/// `playwright-<lockfileHash>-r<8 hex>`. The install REFERENCED by the
/// current configuration is never renamed before the switch: a tree that
/// fails verification is left in place, the replacement is built under a
/// fresh token, the configuration is switched to it, and only then is the
/// old tree quarantined (`quarantineAfterSwitch`). So `mcp.json` never
/// references a directory that this code removed, whatever fails or crashes.
///
/// A staging tree is never deleted unless the bootstrap that created it
/// saw its `npm ci` finish and its process group confirmed gone. A timed-out
/// `npm ci` whose group cannot be confirmed gone (or whose processes cannot
/// be enumerated — treated as alive), and ANY `playwright.staging-*` found
/// already present when a bootstrap starts (a previous Briglia crashed or
/// lost power mid-install; whether its npm survived cannot be known), is
/// PARKED as `playwright.manual-<uuid>/` with a best-effort information file
/// beside it (processes alive at that moment by pid + kernel start time +
/// boot id, for a human with `ps`). If even the park rename fails, the tree
/// stays where it is. Every bootstrap refuses while a parked tree, an
/// information file or a pre-existing staging tree exists, until a human
/// removes them; nothing automatic ever signals, cleans or reuses them.
enum ManagedPlaywright {
    static let serverName = "playwright"
    static let legacyCommand = "npx"
    static let legacyArguments = ["@playwright/mcp@latest"]
    static let markerPrefix = "playwright@"
    static let completionMarkerName = ".briglia-complete"
    static let cliRelativePath = "node_modules/@playwright/mcp/cli.js"
    static let packageRelativePath = "node_modules/@playwright/mcp/package.json"
    static let bundleRelativePath = "MCPBundles/playwright"
    /// The tool every @playwright/mcp release exposes; its presence in
    /// `tools/list` is what distinguishes "a server answered" from "the
    /// Playwright server answered".
    static let requiredTool = "browser_navigate"
    static let npmTimeout: TimeInterval = 600
    /// playwright-core's `engines.node`.
    static let minimumNodeMajor = 20

    // MARK: - Manifests

    struct Manifests: Sendable {
        let packageJSON: Data
        let packageLock: Data
        /// First 16 hex characters of SHA-256(package-lock.json): the
        /// immutable directory name suffix and the `managed` marker.
        let lockfileHash: String

        init(packageJSON: Data, packageLock: Data) {
            self.packageJSON = packageJSON
            self.packageLock = packageLock
            self.lockfileHash = Manifests.hash(of: packageLock)
        }

        static func hash(of lock: Data) -> String {
            String(SHA256.hash(data: lock).map { String(format: "%02x", $0) }.joined().prefix(16))
        }

        static func load(from directory: URL) throws -> Manifests {
            let pkg = try Data(contentsOf: directory.appendingPathComponent("package.json"))
            let lock = try Data(contentsOf: directory.appendingPathComponent("package-lock.json"))
            return Manifests(packageJSON: pkg, packageLock: lock)
        }

        /// The manifests shipped in the resource bundle next to the binary.
        /// Probes for the bundle first: `Bundle.module` traps when it is
        /// missing, and doctor/bundle-check must report, not crash.
        static func bundled() throws -> Manifests {
            let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
                .resolvingSymlinksInPath()
            let bundleURL = executable.deletingLastPathComponent().appendingPathComponent(BundleCheck.bundleName, isDirectory: true)
            guard FileManager.default.fileExists(atPath: bundleURL.path) else {
                throw ManagedError("resource bundle missing next to the binary (\(bundleURL.path))")
            }
            guard let resourceURL = Bundle.module.resourceURL else {
                throw ManagedError("resource bundle has no resource directory")
            }
            return try load(from: resourceURL.appendingPathComponent(bundleRelativePath, isDirectory: true))
        }

        /// The pinned @playwright/mcp version named by the lockfile.
        var pinnedVersion: String? {
            guard let root = try? JSONSerialization.jsonObject(with: packageLock) as? [String: Any],
                  let packages = root["packages"] as? [String: Any],
                  let mcp = packages["node_modules/@playwright/mcp"] as? [String: Any] else { return nil }
            return mcp["version"] as? String
        }

        /// Lockfile sanity (bundle-check and the selftest): lockfile v3, every
        /// dependency resolved with an integrity hash from the public registry,
        /// no install scripts (we run `npm ci --ignore-scripts`; a tree that
        /// needed one would be silently broken).
        func lockfileProblems() -> [String] {
            var problems: [String] = []
            guard let root = try? JSONSerialization.jsonObject(with: packageLock) as? [String: Any] else {
                return ["package-lock.json is not a JSON object"]
            }
            if (root["lockfileVersion"] as? Int) != 3 { problems.append("lockfileVersion is not 3") }
            guard let packages = root["packages"] as? [String: Any] else { return problems + ["no packages map"] }
            if packages["node_modules/@playwright/mcp"] == nil { problems.append("@playwright/mcp missing from the lockfile") }
            for (path, raw) in packages.sorted(by: { $0.key < $1.key }) where !path.isEmpty {
                guard let entry = raw as? [String: Any] else { problems.append("\(path): malformed"); continue }
                let resolved = entry["resolved"] as? String ?? ""
                if !resolved.hasPrefix("https://registry.npmjs.org/") { problems.append("\(path): resolved is not the public registry (\(resolved))") }
                if !(entry["integrity"] as? String ?? "").hasPrefix("sha512-") { problems.append("\(path): no sha512 integrity") }
                if (entry["hasInstallScript"] as? Bool) == true { problems.append("\(path): has an install script (we run npm ci --ignore-scripts)") }
                if (entry["link"] as? Bool) == true { problems.append("\(path): is a link") }
            }
            return problems
        }
    }

    struct ManagedError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    // MARK: - Layout

    struct Layout: Sendable {
        let mcpRoot: URL
        /// An extra assistant's own Chrome profile (MULTI_ASSISTANT_PLAN
        /// §5.3): without it every assistant's browser would default to the
        /// same `ms-playwright-mcp/mcp-<browser>-<hash(cwd)>` profile and the
        /// second one would fail to start. nil for default (unchanged).
        let browserProfile: URL?
        init(dataRoot: URL = StoragePaths.dataRoot, extra: Bool = AssistantProfile.isExtra) {
            mcpRoot = dataRoot.appendingPathComponent("mcp", isDirectory: true)
            browserProfile = extra ? dataRoot.appendingPathComponent("browser-profile", isDirectory: true) : nil
        }
        var installLock: URL { mcpRoot.appendingPathComponent("playwright-install.lock") }
        var statusFile: URL { mcpRoot.appendingPathComponent("playwright-bootstrap.json") }
        func versionDirectory(token: String) -> URL {
            mcpRoot.appendingPathComponent("playwright-\(token)", isDirectory: true)
        }
        func cliPath(token: String) -> String {
            versionDirectory(token: token).appendingPathComponent(cliRelativePath).path
        }
        func stagingDirectory() -> URL {
            mcpRoot.appendingPathComponent("playwright.staging-\(UUID().uuidString.lowercased())", isDirectory: true)
        }
        func corruptDirectory() -> URL {
            mcpRoot.appendingPathComponent("playwright.corrupt-\(UUID().uuidString.lowercased())", isDirectory: true)
        }
        /// A parked staging tree: a name no automatic path ever touches.
        /// The same stem with `.json` holds the information file.
        func manualStem() -> String { "playwright.manual-\(UUID().uuidString.lowercased())" }
        func manualDirectory(stem: String) -> URL { mcpRoot.appendingPathComponent(stem, isDirectory: true) }
        func manualInfoURL(stem: String) -> URL { mcpRoot.appendingPathComponent(stem + ".json") }
        /// Exactly `playwright.staging-<uuid>`: one path component, no
        /// separators, no traversal — the only shape a poison record may name.
        static func isStagingBasename(_ name: String) -> Bool {
            guard name.hasPrefix("playwright.staging-"), !name.contains("/"), !name.contains("..") else { return false }
            let uuid = name.dropFirst("playwright.staging-".count)
            return uuid.count == 36 && uuid.allSatisfy { $0.isHexDigit || $0 == "-" } && !uuid.contains(where: { $0.isUppercase })
        }
        /// A token not yet present for `hash`: the plain hash when free, else
        /// `<hash>-r<8 hex>`.
        func freeToken(hash: String) -> String {
            if !FileManager.default.fileExists(atPath: versionDirectory(token: hash).path) { return hash }
            while true {
                let token = hash + "-r" + String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8))
                if !FileManager.default.fileExists(atPath: versionDirectory(token: token).path) { return token }
            }
        }
        /// `playwright-<token>` → the token; nil for anything else.
        static func token(fromDirectoryName name: String) -> String? {
            guard name.hasPrefix("playwright-") else { return nil }
            let token = String(name.dropFirst("playwright-".count))
            return isValidToken(token) ? token : nil
        }
        /// `<16 hex>` or `<16 hex>-r<8 hex>`, lowercase.
        static func isValidToken(_ token: String) -> Bool {
            func hex(_ s: Substring) -> Bool { !s.isEmpty && s.allSatisfy { $0.isHexDigit && !$0.isUppercase } }
            if token.count == 16 { return hex(token[...]) }
            guard token.count == 26 else { return false }
            let hash = token.prefix(16), rest = token.dropFirst(16)
            return hex(hash) && rest.hasPrefix("-r") && hex(rest.dropFirst(2))
        }
        static func lockfileHash(ofToken token: String) -> String { String(token.prefix(16)) }
        /// Every immutable version directory present (verified or not).
        func installedTokens() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: mcpRoot.path)) ?? [])
                .compactMap(Layout.token(fromDirectoryName:)).sorted()
        }
        /// `manual` lists every manual-recovery leftover: parked trees,
        /// their information files and hold markers.
        func leftovers() -> (staging: [String], corrupt: [String], manual: [String]) {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: mcpRoot.path)) ?? []
            return (names.filter { $0.hasPrefix("playwright.staging-") }.sorted(),
                    names.filter { $0.hasPrefix("playwright.corrupt-") }.sorted(),
                    names.filter { $0.hasPrefix("playwright.manual-") }.sorted())
        }
    }

    // MARK: - Entry shapes

    /// How the `playwright` entry of `mcp.json` relates to the managed install.
    enum EntryShape: Equatable {
        /// No entry.
        case absent
        /// The auto-registered legacy shape (`npx @playwright/mcp@latest`),
        /// enabled: switched to the managed install once one is verified.
        case legacyAuto
        /// A managed entry whose command/args match its marker exactly.
        case managed(token: String)
        /// Carries a managed marker but the command/args were edited by hand
        /// (or the marker is malformed): left alone, reported by doctor.
        case managedEdited
        /// A user-authored entry (own command/args): never touched.
        case userAuthored
        /// Disabled in mcp.json (any shape): left alone, no install is made.
        case disabled
    }

    static func managedMarker(token: String) -> String { markerPrefix + token }

    static func token(fromMarker marker: String) -> String? {
        guard marker.hasPrefix(markerPrefix) else { return nil }
        let token = String(marker.dropFirst(markerPrefix.count))
        return Layout.isValidToken(token) ? token : nil
    }

    /// The exact command/args of a managed entry: `node <cli.js>`. `node` is
    /// deliberately bare — resolved through the augmented MCP PATH at spawn
    /// time (`~/.local/bin` first, where `NodeInstaller` links its copy) —
    /// so a Node reinstall or a Homebrew upgrade never strands the entry.
    static func managedInvocation(token: String, layout: Layout) -> (command: String, arguments: [String]) {
        if let profile = layout.browserProfile {
            return ("node", [layout.cliPath(token: token), "--user-data-dir", profile.path])
        }
        return ("node", [layout.cliPath(token: token)])
    }

    static func shape(of config: MCPServerConfig?, layout: Layout) -> EntryShape {
        guard let config else { return .absent }
        if config.disabled { return .disabled }
        if let marker = config.managed {
            guard let token = token(fromMarker: marker) else { return .managedEdited }
            let expected = managedInvocation(token: token, layout: layout)
            if config.command == expected.command && config.arguments == expected.arguments {
                return .managed(token: token)
            }
            return .managedEdited
        }
        if config.command == legacyCommand && config.arguments == legacyArguments {
            return .legacyAuto
        }
        return .userAuthored
    }

    /// A managed entry for `hash`, keeping everything the existing entry
    /// carried that is not the invocation (env, secretRefs, description,
    /// disabled flag).
    static func managedConfig(token: String, layout: Layout, basedOn existing: MCPServerConfig?) -> MCPServerConfig {
        let invocation = managedInvocation(token: token, layout: layout)
        return MCPServerConfig(
            name: serverName,
            command: invocation.command,
            arguments: invocation.arguments,
            environment: existing?.environment ?? [:],
            disabled: existing?.disabled ?? false,
            secretRefs: existing?.secretRefs ?? [],
            description: existing?.description ?? defaultDescription,
            managed: managedMarker(token: token)
        )
    }

    static let defaultDescription = "Browser automation (drives a local browser for the Browse subagent)"

    // MARK: - Context (production values; the selftest substitutes fakes)

    enum CrashPoint: String, CaseIterable, Sendable {
        case beforeInstall = "before-install"
        case afterInstall = "after-install"
        case afterRename = "after-rename"
        case afterParentFsync = "after-parent-fsync"
        case afterConfigWrite = "after-config-write"
    }

    struct Context: Sendable {
        var layout: Layout
        var manifests: Manifests
        /// Directory holding `node` and `npm`.
        var nodeDirectory: String
        /// Environment for `npm ci` and the verification handshake (the MCP
        /// base environment with `nodeDirectory` first on PATH).
        var environment: [String: String]
        var npmTimeout: TimeInterval = ManagedPlaywright.npmTimeout
        var handshakeTimeout: TimeInterval = 30
        var crashPoint: CrashPoint? = nil
        /// The token the current configuration references (managed shape),
        /// if any: that tree is never renamed before the switch.
        var referencedToken: String? = nil
        var log: @Sendable (String) -> Void = { NSLog("ManagedPlaywright: %@", $0) }

        static func environment(nodeDirectory: String, base: [String: String]) -> [String: String] {
            var env = base
            env["PATH"] = nodeDirectory + ":" + (env["PATH"] ?? "/usr/bin:/bin")
            // npm hygiene: no update banners, no funding notices, non-interactive.
            env["npm_config_update_notifier"] = "false"
            env["NO_UPDATE_NOTIFIER"] = "1"
            env["npm_config_fund"] = "false"
            env["npm_config_audit"] = "false"
            env["CI"] = "1"
            return env
        }
    }

    static func crash(_ point: CrashPoint, if context: Context) {
        guard context.crashPoint == point else { return }
        context.log("crash injection at \(point.rawValue)")
        _exit(137)
    }

    // MARK: - Node resolution

    /// The directory of a usable Node (≥ `minimumNodeMajor`) next to which
    /// `npm` lives, or nil with the reason.
    static func resolveNodeDirectory(preferred: String? = nil) -> (directory: String?, reason: String?) {
        var candidates: [String] = []
        if let preferred { candidates.append(preferred) }
        if let detected = NodeInstaller.detectNode() { candidates.append(detected) }
        var reasons: [String] = []
        for node in candidates {
            let dir = URL(fileURLWithPath: node).deletingLastPathComponent().path
            let probe = runDetached(executable: node, arguments: ["--version"], cwd: nil,
                                    environment: ProcessInfo.processInfo.environment, timeout: 15)
            let version = probe.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard probe.exitCode == 0, let major = Int(version.dropFirst().split(separator: ".").first ?? "") else {
                reasons.append("\(node): does not answer --version"); continue
            }
            guard major >= minimumNodeMajor else {
                reasons.append("\(node) is \(version); Playwright needs Node \(minimumNodeMajor) or newer"); continue
            }
            guard FileManager.default.isExecutableFile(atPath: dir + "/npm") else {
                reasons.append("\(dir)/npm missing next to node"); continue
            }
            return (dir, nil)
        }
        return (nil, reasons.isEmpty ? "node not found" : reasons.joined(separator: "; "))
    }

    // MARK: - Install transaction

    enum InstallOutcome: Equatable, Sendable {
        /// `playwright-<token>` is verified (freshly installed or reused).
        /// `quarantineAfterSwitch` names a tree of the same lockfile that
        /// failed verification while being referenced by the configuration:
        /// the caller quarantines it only AFTER the configuration references
        /// `token`.
        case ready(token: String, reused: Bool, quarantineAfterSwitch: String?)
        /// Another live process holds the installation lock, or a poisoned
        /// process group is still alive; nothing was done.
        case skipped(String)
        /// The install could not be completed; the previous state is intact.
        case failed(String)
    }

    /// The whole transaction under the installation lock. Never touches
    /// `mcp.json` — the caller performs the switch through `MCPRegistry`. On
    /// `.ready` the installation lock is RETURNED still held: the caller keeps
    /// it across the switch and the post-switch quarantine (lock order:
    /// installation → configuration) and releases it afterwards. It is nil
    /// for every other outcome.
    static func ensureInstalled(context: Context) async -> (outcome: InstallOutcome, lock: InstallLock?) {
        let layout = context.layout
        let hash = context.manifests.lockfileHash
        do {
            try PrivateStorage.ensureDirectory(layout.mcpRoot)
        } catch {
            return (.failed("cannot create \(layout.mcpRoot.path): \(error)"), nil)
        }
        let lock: InstallLock
        do {
            guard let acquired = try InstallLock.tryAcquire(layout.installLock) else {
                return (.skipped("installation lock held by another process"), nil)
            }
            lock = acquired
        } catch {
            return (.failed("installation lock: \(error)"), nil)
        }
        var keepLock = false
        defer { if !keepLock { lock.release() } }

        // Manual-recovery leftovers first: refuse to proceed (and to clean
        // anything) while a parked tree or its information file exists — a
        // human removes them.
        if let block = manualRecoveryBlock(layout: layout) {
            return (.skipped(block), nil)
        }
        // A staging tree already present belongs to a bootstrap that did not
        // finish (crash, power loss): whether its npm survived cannot be
        // known, so it is parked, never deleted (Codex, round 4). Refuse.
        if let block = parkPreexistingStaging(layout: layout, log: context.log) {
            return (.skipped(block), nil)
        }
        // Quarantined trees were renamed by an earlier start after failing
        // verification; nothing references or writes them.
        for name in removeLeftovers(layout: layout) { context.log("removed leftover \(name)") }

        crash(.beforeInstall, if: context)

        // Reuse rule: every present tree of this lockfile is a candidate, the
        // referenced one first. The first that verifies is reused. Invalid
        // candidates: unreferenced ones are quarantined now (nothing points
        // at them); the referenced one is NEVER renamed here — it is handed
        // back for quarantine after the switch.
        var candidates = layout.installedTokens().filter { Layout.lockfileHash(ofToken: $0) == hash }
        if let referenced = context.referencedToken, let index = candidates.firstIndex(of: referenced) {
            candidates.remove(at: index)
            candidates.insert(referenced, at: 0)
        }
        var quarantineAfterSwitch: String? = nil
        var chosen: String? = nil
        for token in candidates {
            let dir = layout.versionDirectory(token: token)
            // Full verification (handshake) only until one tree is chosen;
            // the remaining unreferenced trees get the static checks so an
            // invalid leftover is still quarantined without a spawn each.
            if let problem = await verify(directory: dir, expectedHash: hash, context: context, handshake: chosen == nil) {
                if case .transient(let reason) = problem {
                    // Not a verdict: a slow handshake never quarantines or
                    // replaces a tree. The referenced one keeps its place and
                    // this start ends here; an unreferenced one is skipped.
                    if token == context.referencedToken {
                        return (.skipped("could not verify the referenced \(dir.lastPathComponent) this start: \(reason) — left as is, retried at the next start"), nil)
                    }
                    context.log("\(dir.lastPathComponent): \(reason) — skipped this start")
                    continue
                }
                if token == context.referencedToken {
                    context.log("referenced \(dir.lastPathComponent) failed verification (\(problem.description)) — kept in place until a replacement is switched in")
                    quarantineAfterSwitch = token
                } else {
                    context.log("\(dir.lastPathComponent) failed verification (\(problem.description)) — quarantining if still unreferenced")
                    switch quarantineIfUnreferenced(token: token, layout: layout) {
                    case .quarantined: break
                    case .referenced:
                        // An edit landed meanwhile and points at it: not ours
                        // to rename now; the next start sees it as the
                        // referenced invalid tree and repairs it in place.
                        context.log("\(dir.lastPathComponent) became referenced — left in place")
                    case .failed(let failure):
                        return (.failed(failure), nil)
                    }
                }
                continue
            }
            if chosen == nil { chosen = token }
        }
        if let chosen {
            keepLock = true
            return (.ready(token: chosen, reused: true, quarantineAfterSwitch: quarantineAfterSwitch), lock)
        }

        // Staging build under a token that is not present yet.
        let token = layout.freeToken(hash: hash)
        let versionDir = layout.versionDirectory(token: token)
        let staging = layout.stagingDirectory()
        func abandon(_ reason: String) -> (InstallOutcome, InstallLock?) {
            try? FileManager.default.removeItem(at: staging)
            return (.failed(reason), nil)
        }
        do {
            try PrivateStorage.ensureDirectory(staging)
            try PrivateStorage.writeAtomically(context.manifests.packageJSON, to: staging.appendingPathComponent("package.json"))
            try PrivateStorage.writeAtomically(context.manifests.packageLock, to: staging.appendingPathComponent("package-lock.json"))
        } catch {
            return abandon("staging: \(error)")
        }
        let npm = context.nodeDirectory + "/npm"
        guard FileManager.default.isExecutableFile(atPath: npm) else {
            return abandon("npm not found at \(npm)")
        }
        var env = context.environment
        // Everything npm creates lands under the data root: owner-only from
        // creation (the trampoline applies the umask and drops the variable).
        env["BRIGLIA_CHILD_UMASK"] = "077"
        let run = runDetached(
            executable: npm,
            arguments: ["ci", "--ignore-scripts", "--omit=dev", "--no-audit", "--no-fund", "--no-progress", "--loglevel=error"],
            cwd: staging, environment: env, timeout: context.npmTimeout)
        guard run.exitCode == 0 else {
            let tail = run.output.split(separator: "\n").suffix(6).joined(separator: " | ")
            let detail = run.exitCode == 124 ? "npm ci timed out after \(Int(context.npmTimeout))s" : "npm ci exited \(run.exitCode)"
            if run.processGroupVerifiedGone == false, let pgid = run.processGroupID {
                // Descendants may still be alive and writing into staging —
                // or could not even be enumerated. Park the tree for a human;
                // nothing automatic touches it again (Codex, round 3 #1).
                let parked = parkStaging(staging, layout: layout, processGroup: pgid, reason: detail)
                return (.failed("\(detail); the process group could not be confirmed gone — \(parked)"), nil)
            }
            return abandon("\(detail): \(tail)")
        }
        if let problem = await verify(directory: staging, expectedHash: nil, context: context) {
            return abandon("staged install failed verification: \(problem.description)")
        }
        do {
            try PrivateStorage.writeAtomically(Data((hash + "\n").utf8), to: staging.appendingPathComponent(completionMarkerName))
        } catch {
            return abandon("completion marker: \(error)")
        }

        crash(.afterInstall, if: context)

        // Publish: durable tree, then the atomic rename, then the parent.
        do {
            try fsyncTree(staging.path)
        } catch {
            return abandon("fsync of the staged tree: \(error)")
        }
        guard rename(staging.path, versionDir.path) == 0 else {
            return abandon("cannot publish \(versionDir.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        crash(.afterRename, if: context)
        do {
            try PrivateStorage.fsyncDirectory(layout.mcpRoot.path)
        } catch {
            return (.failed("fsync after publish: \(error)"), nil)
        }
        crash(.afterParentFsync, if: context)
        keepLock = true
        return (.ready(token: token, reused: false, quarantineAfterSwitch: quarantineAfterSwitch), lock)
    }

    /// Selftest seam: substitute the park rename (to simulate its failure).
    nonisolated(unsafe) static var parkRenameOverride: ((String, String) -> Int32)?

    /// Parks a staging tree whose writers may still be alive: rename to
    /// `playwright.manual-<uuid>/` (parent fsync checked), best-effort
    /// information file beside it. If the rename fails, the tree stays
    /// under its staging name — which blocks every later bootstrap just the
    /// same (`parkPreexistingStaging` finds it again and retries the park).
    /// Returns the sentence for the failure message.
    static func parkStaging(_ staging: URL, layout: Layout, processGroup: Int32?, reason: String) -> String {
        let stem = layout.manualStem()
        let manual = layout.manualDirectory(stem: stem)
        let members = processGroup.flatMap { ProcessGroups.members(of: $0)?.filter { !$0.zombie }.map(\.identity) }
        let info = ManualRecoveryInfo(stagingDirectory: staging.lastPathComponent, parkedAs: stem, processGroup: processGroup,
                                      members: members, enumerationFailed: processGroup != nil && members == nil,
                                      bootID: ProcessGroups.bootID(), at: Date(), reason: reason)
        let renameResult = parkRenameOverride?(staging.path, manual.path) ?? rename(staging.path, manual.path)
        guard renameResult == 0 else {
            let renameError = String(cString: strerror(errno))
            return "\(staging.lastPathComponent) could not be parked (\(renameError)); it stays in place and blocks bootstraps until it is removed by hand"
        }
        var note = "staging parked as \(stem) for manual recovery (bootstraps refuse until it is removed by hand)"
        do { try PrivateStorage.fsyncDirectory(layout.mcpRoot.path) } catch { note += "; parent fsync failed: \(error)" }
        if let data = try? JSONEncoder.iso.encode(info) {
            try? PrivateStorage.writeAtomically(data, to: layout.manualInfoURL(stem: stem))
        }
        return note
    }

    /// Parks every `playwright.staging-*` already present (lock held; ours is
    /// created only afterwards). Returns the refusal, or nil when none.
    static func parkPreexistingStaging(layout: Layout, log: @Sendable (String) -> Void) -> String? {
        let staging = layout.leftovers().staging
        guard !staging.isEmpty else { return nil }
        var notes: [String] = []
        for name in staging {
            let note = parkStaging(layout.mcpRoot.appendingPathComponent(name, isDirectory: true), layout: layout,
                                   processGroup: nil, reason: "found at start: a previous install was interrupted (crash or power loss); whether its npm survived cannot be known")
            log("pre-existing \(name): \(note)")
            notes.append(note)
        }
        return "an interrupted install was found — \(notes.joined(separator: "; ")); end any npm/node from it (ps -o pid,pgid,etime,args), then remove every playwright.manual-* entry under \(layout.mcpRoot.path) by hand; nothing installed this start"
    }

    struct ManualRecoveryInfo: Codable, Equatable {
        var stagingDirectory: String
        var parkedAs: String
        /// Nil when the tree was found already present at a later start.
        var processGroup: Int32?
        /// Processes alive in the group when parked (nil: enumeration failed).
        var members: [ProcessGroups.Identity]?
        var enumerationFailed: Bool
        var bootID: String?
        var at: Date
        var reason: String
    }

    enum QuarantineResult: Equatable {
        case quarantined
        /// `mcp.json` references the token (managed shape): left untouched.
        case referenced
        case failed(String)
    }

    /// Selftest seam: runs after the decision to quarantine and BEFORE the
    /// configuration lock is taken (the window an external edit can use).
    nonisolated(unsafe) static var testHookBeforeQuarantineLock: ((String) -> Void)?

    /// Renames `playwright-<token>` to `playwright.corrupt-<uuid>` only if,
    /// re-read under the configuration lock, `mcp.json` PROVABLY does not
    /// reference it: the file is absent, or it parses and no server entry
    /// carries the token's managed marker or names the installation path
    /// in its command/args (any entry, edited or user-authored). A file
    /// that exists but cannot be read or parsed is uncertainty, and
    /// uncertainty keeps the directory (Codex, round 3 #2). Lock order
    /// everywhere: installation lock (held by the caller) → configuration
    /// lock (taken here).
    static func quarantineIfUnreferenced(token: String, layout: Layout) -> QuarantineResult {
        testHookBeforeQuarantineLock?(token)
        do {
            return try MCPAgentRouting.withConfigLock {
                let url = MCPRegistry.configFileURL
                if FileManager.default.fileExists(atPath: url.path) {
                    guard let data = FileManager.default.contents(atPath: url.path),
                          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let servers = root["mcpServers"] as? [String: Any] else {
                        return .failed("mcp.json exists but cannot be read or parsed — not quarantining playwright-\(token)")
                    }
                    if configReferences(token: token, servers: servers, layout: layout) { return .referenced }
                }
                let dir = layout.versionDirectory(token: token)
                let corrupt = layout.corruptDirectory()
                guard rename(dir.path, corrupt.path) == 0 else {
                    return .failed("cannot quarantine \(dir.lastPathComponent): \(String(cString: strerror(errno)))")
                }
                do { try PrivateStorage.fsyncDirectory(layout.mcpRoot.path) } catch {
                    return .failed("fsync after quarantine: \(error)")
                }
                return .quarantined
            }
        } catch {
            return .failed("config lock: \(error)")
        }
    }

    /// True when any server entry carries the token's managed marker or
    /// names the token's installation path in its command or arguments.
    static func configReferences(token: String, servers: [String: Any], layout: Layout) -> Bool {
        let marker = managedMarker(token: token)
        let dirPath = layout.versionDirectory(token: token).path
        for raw in servers.values {
            guard let entry = raw as? [String: Any] else { continue }
            if (entry["managed"] as? String) == marker { return true }
            var strings: [String] = []
            if let command = entry["command"] as? String { strings.append(command) }
            if let args = entry["args"] as? [String] { strings += args }
            if strings.contains(where: { $0 == dirPath || $0.hasPrefix(dirPath + "/") }) { return true }
        }
        return false
    }

    /// Any manual-recovery leftover refuses the start; nothing is touched.
    static func manualRecoveryBlock(layout: Layout) -> String? {
        let manual = layout.leftovers().manual
        guard let first = manual.first else { return nil }
        return "\(first) is parked for manual recovery (an install whose processes could not be confirmed gone) — end any npm/node from it (ps -o pid,pgid,etime,args), then remove every playwright.manual-* entry under \(layout.mcpRoot.path) by hand; nothing installed this start"
    }

    /// Removes quarantined directories (lock must be held). Staging trees are
    /// never removed here — a pre-existing one is parked before this runs —
    /// and immutable `playwright-<token>` directories are never touched.
    @discardableResult
    static func removeLeftovers(layout: Layout) -> [String] {
        let leftovers = layout.leftovers()
        var removed: [String] = []
        for name in leftovers.corrupt {
            let url = layout.mcpRoot.appendingPathComponent(name)
            if (try? FileManager.default.removeItem(at: url)) != nil { removed.append(name) }
        }
        return removed
    }

    // MARK: - Verification

    /// Nil when the tree at `directory` is a usable Playwright install:
    /// completion marker (when `expectedHash` is given) carrying the hash,
    /// the pinned package present at the pinned version, the executable
    /// present, and a live `initialize` handshake whose `tools/list` includes
    /// `browser_navigate`. Otherwise the reason.
    enum VerifyProblem: Equatable {
        /// The tree is structurally wrong (missing files, wrong version,
        /// server exits or answers wrongly): quarantine/rebuild territory.
        case invalid(String)
        /// The tree could not be judged right now (the handshake timed out —
        /// a loaded or slow machine, not a broken install): keep it, retry at
        /// a later start.
        case transient(String)

        var description: String {
            switch self {
            case .invalid(let s): return s
            case .transient(let s): return s
            }
        }
    }

    static func verify(directory: URL, expectedHash: String?, context: Context, handshake: Bool = true) async -> VerifyProblem? {
        let fm = FileManager.default
        if let expectedHash {
            let marker = directory.appendingPathComponent(completionMarkerName)
            guard let text = try? String(contentsOf: marker, encoding: .utf8) else {
                return .invalid("no completion marker")
            }
            guard text.trimmingCharacters(in: .whitespacesAndNewlines) == expectedHash else {
                return .invalid("completion marker names another lockfile")
            }
        }
        let cli = directory.appendingPathComponent(cliRelativePath).path
        guard fm.fileExists(atPath: cli) else { return .invalid("\(cliRelativePath) missing") }
        if let pinned = context.manifests.pinnedVersion {
            guard let data = fm.contents(atPath: directory.appendingPathComponent(packageRelativePath).path),
                  let pkg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = pkg["version"] as? String else {
                return .invalid("installed package.json unreadable")
            }
            guard version == pinned else { return .invalid("installed @playwright/mcp \(version) is not the pinned \(pinned)") }
        }
        guard handshake else { return nil }
        let config = MCPServerConfig(name: "playwright-verify", command: context.nodeDirectory + "/node", arguments: [cli])
        let client = MCPClient(config: config, resolvedEnvironment: context.environment)
        do {
            try await client.start()
            try await client.initialize(timeout: context.handshakeTimeout)
        } catch {
            await client.shutdown()
            if case MCPClientError.timedOut = error {
                return .transient("handshake timed out after \(Int(context.handshakeTimeout))s (machine busy or slow — not treated as a broken install)")
            }
            return .invalid("handshake failed: \(error)")
        }
        let tools = await client.listedTools
        await client.shutdown()
        guard tools.contains(where: { $0.toolName == requiredTool }) else {
            return .invalid("server answered but exposes no \(requiredTool) (\(tools.count) tools)")
        }
        return nil
    }

    /// Bottom-up durability of a staged tree: every regular file, then every
    /// directory deepest-first, the root last. Symlinks are skipped (their
    /// entries are covered by their directory's fsync).
    static func fsyncTree(_ root: String) throws {
        let fm = FileManager.default
        var files: [String] = []
        var dirs: [(path: String, depth: Int)] = [(root, 0)]
        func walk(_ dir: String, depth: Int) throws {
            for name in try fm.contentsOfDirectory(atPath: dir) {
                let path = dir + "/" + name
                var st = stat()
                guard lstat(path, &st) == 0 else { throw ManagedError("lstat \(path): \(String(cString: strerror(errno)))") }
                let fmt = st.st_mode & S_IFMT
                if fmt == S_IFDIR {
                    dirs.append((path, depth + 1))
                    try walk(path, depth: depth + 1)
                } else if fmt == S_IFREG {
                    files.append(path)
                }
            }
        }
        try walk(root, depth: 0)
        for path in files { try fsyncPath(path) }
        for entry in dirs.sorted(by: { $0.depth > $1.depth }) { try fsyncPath(entry.path) }
    }

    private static func fsyncPath(_ path: String) throws {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw ManagedError("open \(path): \(String(cString: strerror(errno)))") }
        let rc = fsync(fd)
        let code = errno
        close(fd)
        guard rc == 0 else { throw ManagedError("fsync \(path): \(String(cString: strerror(code)))") }
    }

    // MARK: - Installation lock

    final class InstallLock {
        private var fd: Int32
        private init(fd: Int32) { self.fd = fd }

        /// Exclusive, non-blocking. Nil when another process holds it.
        static func tryAcquire(_ url: URL) throws -> InstallLock? {
            let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
            guard fd >= 0 else {
                throw ManagedError("cannot open \(url.path): \(String(cString: strerror(errno)))")
            }
            if flock(fd, LOCK_EX | LOCK_NB) != 0 {
                let code = errno
                close(fd)
                if code == EWOULDBLOCK || code == EAGAIN { return nil }
                throw ManagedError("flock \(url.path): \(String(cString: strerror(code)))")
            }
            return InstallLock(fd: fd)
        }

        func release() {
            guard fd >= 0 else { return }
            flock(fd, LOCK_UN)
            close(fd)
            fd = -1
        }

        deinit { release() }
    }

    // MARK: - Detached process runner (own process group, bounded)

    struct RunResult {
        let exitCode: Int32
        let output: String
        /// After a timeout: whether the child's process group was confirmed
        /// gone (no live member) before the runner returned. Nil when no
        /// timeout occurred.
        let processGroupVerifiedGone: Bool?
        /// The group that was signalled (the detached leader), for the
        /// poisoned record when it could not be confirmed gone.
        var processGroupID: Int32? = nil
    }

    /// Runs `executable` through the `__setsid-exec` trampoline so the whole
    /// tree is one session/process group; on timeout SIGTERM, a short grace,
    /// SIGKILL, `waitpid` of the direct child, then the group is polled until
    /// `kill(-pgid, 0)` fails with ESRCH (a `waitpid` cannot reap
    /// grandchildren). Mirrors `UserdataToolchain.run` with an explicit
    /// environment and the group verification the plan requires.
    static func runDetached(executable: String, arguments: [String], cwd: URL?,
                            environment: [String: String], timeout: TimeInterval) -> RunResult {
        let process = Process()
        let (exe, launchArgs) = BashTools.detachedInvocation(executable: executable, arguments: arguments)
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = launchArgs
        if let cwd { process.currentDirectoryURL = cwd }
        var env = environment
        let pgidFile = FileManager.default.temporaryDirectory.appendingPathComponent(
            "briglia-playwright-pgid-\(UUID().uuidString)")
        env["BRIGLIA_SETSID_PGID_FILE"] = pgidFile.path
        defer { try? FileManager.default.removeItem(at: pgidFile) }
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        var data = Data()
        do {
            try process.run()
        } catch {
            return RunResult(exitCode: 127, output: "launch failed: \(error.localizedDescription)", processGroupVerifiedGone: nil)
        }
        let reader = Thread { data = pipe.fileHandleForReading.readDataToEndOfFile() }
        reader.start()
        let pid = process.processIdentifier
        func leaderPid() -> Int32? {
            guard let text = try? String(contentsOfFile: pgidFile.path, encoding: .utf8),
                  let leader = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), leader > 0 else { return nil }
            return leader
        }
        func signalTree(_ sig: Int32) {
            if let leader = leaderPid() { kill(-leader, sig) }
            if kill(-pid, sig) != 0 { kill(pid, sig) }
        }
        func groupGone() -> Bool {
            !processGroupHasLiveMembers(leaderPid() ?? pid)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning {
            signalTree(SIGTERM)
            let grace = Date().addingTimeInterval(2)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.1) }
            if process.isRunning { signalTree(SIGKILL) }
            process.waitUntilExit()
            signalTree(SIGKILL)
            let groupDeadline = Date().addingTimeInterval(20)
            var gone = groupGone()
            while !gone && Date() < groupDeadline {
                Thread.sleep(forTimeInterval: 0.1)
                signalTree(SIGKILL)
                gone = groupGone()
            }
            let readerDeadline = Date().addingTimeInterval(5)
            while reader.isExecuting && Date() < readerDeadline { Thread.sleep(forTimeInterval: 0.05) }
            let captured = reader.isExecuting
                ? "(output unavailable — a straggler still holds the pipe)"
                : (String(data: data, encoding: .utf8) ?? "")
            return RunResult(exitCode: 124, output: "timed out after \(Int(timeout))s\n" + captured,
                             processGroupVerifiedGone: gone, processGroupID: leaderPid() ?? pid)
        }
        // Leader exited: bounded wait for the pipe (a detached child could
        // hold it), then kill whatever is left in the group.
        while reader.isExecuting && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        var stragglers = false
        if reader.isExecuting {
            stragglers = true
            signalTree(SIGTERM)
            let grace = Date().addingTimeInterval(2)
            while reader.isExecuting && Date() < grace { Thread.sleep(forTimeInterval: 0.05) }
            if reader.isExecuting {
                signalTree(SIGKILL)
                let finalJoin = Date().addingTimeInterval(5)
                while reader.isExecuting && Date() < finalJoin { Thread.sleep(forTimeInterval: 0.05) }
            }
        }
        process.waitUntilExit()
        if reader.isExecuting {
            return RunResult(exitCode: 124, output: "the command exited but a detached descendant still holds its output pipe — process group killed, output unavailable",
                             processGroupVerifiedGone: groupGone(), processGroupID: leaderPid() ?? pid)
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        if stragglers {
            let status = process.terminationStatus
            return RunResult(exitCode: status == 0 ? 124 : status,
                             output: text + "\n(detached descendant processes outlived the command and were killed — treated as failure)",
                             processGroupVerifiedGone: groupGone(), processGroupID: leaderPid() ?? pid)
        }
        return RunResult(exitCode: process.terminationStatus, output: text, processGroupVerifiedGone: nil)
    }

    /// True while any NON-zombie process belongs to `pgid`. `kill(-pgid, 0)`
    /// alone also counts zombies: in a container whose PID 1 does not reap
    /// (GitHub's Swift container), a killed grandchild of npm stays a zombie
    /// forever and the group would never read as gone. On Linux `/proc` gives
    /// the state; elsewhere launchd reaps orphans and the kill probe suffices.
    /// Alive unless PROVEN otherwise: an enumeration that succeeds and
    /// lists no live member means gone; an enumeration that fails falls
    /// back to `kill(-pgid, 0)`, where only ESRCH (no process at all in the
    /// group, zombies included) means gone. Anything else is "alive" and
    /// leads to parking, never to cleanup.
    static func processGroupHasLiveMembers(_ pgid: Int32) -> Bool {
        if let members = ProcessGroups.members(of: pgid) {
            return members.contains { !$0.zombie }
        }
        return !(kill(-pgid, 0) == -1 && errno == ESRCH)
    }

    // MARK: - Process identity

    /// Enumerates the processes of a process group with an identity that a
    /// reused pid cannot forge: pid + kernel start time (+ the boot id at the
    /// record level). Linux reads `/proc/<pid>/stat`; macOS asks
    /// `sysctl KERN_PROC_PGRP`. Zombies are reported as such (a container
    /// without a reaper keeps them forever; they hold no files).
    enum ProcessGroups {
        struct Identity: Codable, Equatable, Hashable {
            let pid: Int32
            let startTime: UInt64
        }
        struct Member: Equatable {
            let identity: Identity
            let zombie: Bool
        }

        /// Selftest seam: substitute the enumeration (nil = "enumeration failed").
        nonisolated(unsafe) static var membersOverride: ((Int32) -> [Member]?)?

        /// The group's processes, or nil when they cannot be enumerated
        /// (unreadable `/proc`, failing `sysctl`) — callers treat nil as
        /// "may be alive".
        static func members(of pgid: Int32) -> [Member]? {
            if let membersOverride { return membersOverride(pgid) }
            return enumerate()?.filter { $0.pgid == pgid }.map { Member(identity: Identity(pid: $0.pid, startTime: $0.start), zombie: $0.zombie) }
        }

        /// Diagnostic only (doctor): those of `recorded` that exist right
        /// now with the same start time and are not zombies; nil when the
        /// enumeration fails.
        static func stillAlive(_ recorded: [Identity]) -> [Identity]? {
            let current: [Member]?
            if let membersOverride {
                current = membersOverride(-1)
            } else {
                current = enumerate()?.map { Member(identity: Identity(pid: $0.pid, startTime: $0.start), zombie: $0.zombie) }
            }
            guard let current else { return nil }
            return recorded.filter { id in current.contains { $0.identity == id && !$0.zombie } }
        }

        private struct Raw { let pid: Int32; let pgid: Int32; let start: UInt64; let zombie: Bool }

        private static func enumerate() -> [Raw]? {
            #if os(Linux)
            var out: [Raw] = []
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else { return nil }
            for name in names {
                guard let pid = Int32(name),
                      let stat = try? String(contentsOfFile: "/proc/\(name)/stat", encoding: .utf8),
                      let close = stat.range(of: ")", options: .backwards) else { continue }
                // After the parenthesised comm: state ppid pgrp session tty tpgid flags minflt cminflt majflt cmajflt utime stime cutime cstime priority nice threads itrealvalue starttime …
                let fields = stat[close.upperBound...].split(separator: " ")
                guard fields.count > 19, let pgid = Int32(fields[2]), let start = UInt64(fields[19]) else { continue }
                out.append(Raw(pid: pid, pgid: pgid, start: start, zombie: fields[0] == "Z"))
            }
            return out
            #else
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
            var size = 0
            guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var buffer = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 16)
            var actual = buffer.count * MemoryLayout<kinfo_proc>.stride
            guard sysctl(&mib, 4, &buffer, &actual, nil, 0) == 0 else { return nil }
            let count = actual / MemoryLayout<kinfo_proc>.stride
            return buffer.prefix(count).map { proc in
                let tv = proc.kp_proc.p_starttime
                let start = UInt64(tv.tv_sec) &* 1_000_000 &+ UInt64(tv.tv_usec)
                return Raw(pid: proc.kp_proc.p_pid, pgid: proc.kp_eproc.e_pgid, start: start,
                           zombie: Int32(proc.kp_proc.p_stat) == SZOMB)
            }
            #endif
        }

        /// A per-boot value: after a reboot every recorded process is gone
        /// by definition, whatever pids and start times say.
        static func bootID() -> String? {
            #if os(Linux)
            return (try? String(contentsOfFile: "/proc/sys/kernel/random/boot_id", encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #else
            var tv = timeval()
            var size = MemoryLayout<timeval>.size
            guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return nil }
            return "\(tv.tv_sec).\(tv.tv_usec)"
            #endif
        }
    }

    // MARK: - Bootstrap status (doctor)

    struct BootstrapStatus: Codable, Equatable {
        var at: Date
        /// `ready` | `skipped` | `failed` | `left-alone`
        var outcome: String
        var token: String?
        var reason: String?
    }

    static func recordStatus(_ status: BootstrapStatus, layout: Layout) {
        guard let data = try? JSONEncoder.iso.encode(status) else { return }
        try? PrivateStorage.ensureDirectory(layout.mcpRoot)
        try? PrivateStorage.writeAtomically(data, to: layout.statusFile)
    }

    static func readStatus(layout: Layout) -> BootstrapStatus? {
        guard let data = FileManager.default.contents(atPath: layout.statusFile.path) else { return nil }
        return try? JSONDecoder.iso.decode(BootstrapStatus.self, from: data)
    }

    // MARK: - Doctor

    struct Finding {
        let text: String
        let problem: Bool
        let hint: String?
    }

    /// Read-only report for `briglia doctor`: the entry's shape, whether the
    /// referenced install carries its marker, unreferenced and leftover
    /// directories, the last bootstrap outcome.
    static func doctorFindings(configs: [MCPServerConfig], layout: Layout,
                               bundledHash: String?) -> [Finding] {
        var out: [Finding] = []
        let entry = configs.first { $0.name == serverName }
        let installed = layout.installedTokens()
        var referenced: String? = nil
        switch shape(of: entry, layout: layout) {
        case .absent:
            out.append(Finding(text: "playwright: not registered (the Browse subagent is unavailable)", problem: false, hint: nil))
        case .legacyAuto:
            out.append(Finding(text: "playwright: legacy `npx @playwright/mcp@latest` entry — switched to the pinned managed install at the next successful start",
                               problem: false, hint: nil))
        case .managed(let token):
            referenced = token
            let marker = layout.versionDirectory(token: token).appendingPathComponent(completionMarkerName)
            let hash = Layout.lockfileHash(ofToken: token)
            let ok = (try? String(contentsOf: marker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == hash
            let current = bundledHash == nil || bundledHash == hash
            out.append(Finding(text: "playwright: managed install playwright-\(token)\(current ? "" : " (this build pins \(bundledHash ?? "?") — updated at the next successful start)")",
                               problem: !ok,
                               hint: ok ? nil : "the referenced directory is missing or incomplete — start briglia once, the bootstrap installs a replacement and re-points the entry"))
        case .managedEdited:
            out.append(Finding(text: "playwright: managed marker present but command/args were edited by hand — left alone (remove the `managed` field to make that permanent)", problem: false, hint: nil))
        case .userAuthored:
            out.append(Finding(text: "playwright: user-authored entry (\(entry?.command ?? "") \(entry?.arguments.joined(separator: " ") ?? "")) — not managed", problem: false, hint: nil))
        case .disabled:
            out.append(Finding(text: "playwright: disabled in mcp.json", problem: false, hint: nil))
        }
        let unreferenced = installed.filter { $0 != referenced }
        if !unreferenced.isEmpty {
            out.append(Finding(text: "unreferenced managed versions kept (never auto-deleted): \(unreferenced.map { "playwright-\($0)" }.joined(separator: ", ")) — remove by hand under \(layout.mcpRoot.path) if unwanted",
                               problem: false, hint: nil))
        }
        let leftovers = layout.leftovers()
        if !leftovers.corrupt.isEmpty {
            out.append(Finding(text: "quarantined directories removed at the next start: \(leftovers.corrupt.joined(separator: ", "))",
                               problem: false, hint: nil))
        }
        for name in leftovers.manual where !name.hasSuffix(".json") {
            let info = FileManager.default.contents(atPath: layout.manualInfoURL(stem: name).path)
                .flatMap { try? JSONDecoder.iso.decode(ManualRecoveryInfo.self, from: $0) }
            var detail = "an install whose processes could not be confirmed gone"
            var hint = "make sure no npm/node from it is still running (ps -o pid,pgid,etime,args), then remove every playwright.manual-* entry under \(layout.mcpRoot.path)"
            if let info {
                if info.processGroup == nil {
                    detail = "found already present at a later start: a previous install was interrupted"
                } else if info.enumerationFailed {
                    detail += "; process enumeration failed when it was parked (group \(info.processGroup ?? 0))"
                } else if let members = info.members {
                    let alive = info.bootID == ProcessGroups.bootID() ? ProcessGroups.stillAlive(members) : []
                    if let alive, !alive.isEmpty {
                        detail += "; still alive now: pid \(alive.map { String($0.pid) }.joined(separator: ", "))"
                        hint = "end pid \(alive.map { String($0.pid) }.joined(separator: ", ")) first, then remove every playwright.manual-* entry under \(layout.mcpRoot.path)"
                    } else if alive == nil {
                        detail += "; cannot enumerate processes right now"
                    } else {
                        detail += "; none of the \(members.count) recorded process(es) is alive now"
                    }
                }
            }
            out.append(Finding(text: "\(name) is parked for manual recovery (\(detail)): bootstraps refuse", problem: true, hint: hint))
        }
        for name in leftovers.staging {
            out.append(Finding(text: "\(name): an interrupted install (parked for manual recovery at the next start; never deleted automatically)",
                               problem: true,
                               hint: "make sure no npm/node from it is still running, then remove it under \(layout.mcpRoot.path)"))
        }
        if let status = readStatus(layout: layout) {
            let fmt = ISO8601DateFormatter()
            let reason = status.reason.map { " — \($0)" } ?? ""
            out.append(Finding(text: "last bootstrap \(fmt.string(from: status.at)): \(status.outcome)\(reason)",
                               problem: status.outcome == "failed",
                               hint: status.outcome == "failed" ? "the previous entry keeps working; the next start retries" : nil))
        }
        return out
    }
}

extension JSONEncoder {
    /// ISO-8601 dates, stable key order (the small state files under mcp/).
    static var iso: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
