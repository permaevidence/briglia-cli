import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// MARK: - AgentMail CLI: Briglia-private install (security plan v24 §7.8.1, §7.9.2)
//
// The pinned AgentMail CLI lives ONLY under
// ~/.local/share/briglia/runtime/agentmail/ (receipt, `current` link,
// private journal, hold) and is reached through the Briglia-only wrapper
// ~/.local/share/briglia/bin/agentmail, which execs `briglia __agentmail-exec`:
// validation at every use, then the key, then execv. Anything an older
// Briglia left in ~/.local/bin is inspected and reported, never touched.

extension AgentMailService {
    static let wrapperName = "agentmail"
    static let legacyBinaryName = "agentmail-bin"
    static let legacyTransactionFileName = "agentmail.tx.json"
    /// The binary's name inside a private version directory.
    static let privateBinaryName = "agentmail-bin"
    /// Placeholder key for probes: never a real credential.
    static let probePlaceholderKey = "briglia-probe-placeholder"

    // MARK: Pinned upstream release
    //
    // The upstream CLI is pinned to ONE version whose per-target archive
    // SHA-256 is compiled in: the installer never asks GitHub for "latest",
    // and the archive is authenticated against Briglia's own record instead
    // of a sidecar served from the same origin. Bumping = new version +
    // hashes here (the release gate, plan §3.5, refuses a stale pin).
    static let pinnedVersion = "1.3.0"
    /// Target triple → SHA-256 of `agentmail-cli-<triple>.tar.gz` for
    /// `pinnedVersion`. Linux uses the musl builds: statically linked, no
    /// libssl.so.3 requirement (the gnu builds need OpenSSL 3 on the host).
    static let pinnedArchiveSHA256: [String: String] = [
        "aarch64-apple-darwin":       "01177d7b2d020da2d00d1eeede4fcfec427c0eefaf15997a7c3aad2f6361a365",
        "x86_64-apple-darwin":        "6c143440548c1b0f61ca8976f68c0a4ff945af5c4531c3b87470abae82ba435c",
        "aarch64-unknown-linux-musl": "2bf5310c9ca534da7674f744001bbd5d65145f24ce79fdb19d0bfe495237364b",
        "x86_64-unknown-linux-musl":  "993d8ef53b1e46b229d58cb04bc37526f3055ba3907679b9004379d36ee31165",
    ]
    static var currentTargetTriple: String {
        #if os(Linux)
        #if arch(arm64)
        return "aarch64-unknown-linux-musl"
        #else
        return "x86_64-unknown-linux-musl"
        #endif
        #else
        #if arch(arm64)
        return "aarch64-apple-darwin"
        #else
        return "x86_64-apple-darwin"
        #endif
        #endif
    }
    /// The pinned archive for a target: asset name, download URL and the
    /// expected SHA-256. Nil for a target without a pinned build.
    static func pinnedAsset(triple: String = currentTargetTriple) -> (asset: String, url: URL, sha256: String)? {
        guard let sha = pinnedArchiveSHA256[triple] else { return nil }
        let asset = "agentmail-cli-\(triple).tar.gz"
        guard let url = URL(string: "https://github.com/agentmail-to/agentmail-cli/releases/download/v\(pinnedVersion)/\(asset)") else { return nil }
        return (asset, url, sha)
    }

    /// The compiled pin for this machine; development builds may point it at
    /// a local fixture archive (`BRIGLIA_AGENTMAIL_TEST_ARCHIVE` + `_SHA256`
    /// + `_VERSION`) for the selftests. Release builds ignore those.
    static var runtimePin: RuntimePin? {
        if let sha = RuntimeSeams.env("BRIGLIA_AGENTMAIL_TEST_SHA256"), let v = RuntimeSeams.env("BRIGLIA_AGENTMAIL_TEST_VERSION") {
            return RuntimePin(triple: currentTargetTriple, version: v, archiveSHA256: sha)
        }
        guard let a = pinnedAsset() else { return nil }
        return RuntimePin(triple: currentTargetTriple, version: pinnedVersion, archiveSHA256: a.sha256)
    }

    /// Selftest seam: the exact path of the `briglia` binary the wrapper calls.
    nonisolated(unsafe) static var brigliaPathOverride: String?
    static func brigliaPath() -> String {
        brigliaPathOverride ?? (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath().path
    }

    // MARK: Paths

    /// Legacy (inspect-only): ~/.local/bin. Selftest seam for its location.
    nonisolated(unsafe) static var legacyDirectoryOverride: URL?
    static var legacyDirectory: URL {
        legacyDirectoryOverride
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin", isDirectory: true)
    }
    static var legacyWrapperURL: URL { legacyDirectory.appendingPathComponent(wrapperName) }
    /// The Briglia-only wrapper (first on the agent's PATH).
    static var wrapperURL: URL { RuntimePaths.binDir.appendingPathComponent(wrapperName) }

    // MARK: Spec

    static func runtimeSpec(pin: RuntimePin) -> RuntimeSpec {
        RuntimeSpec(
            component: .agentmail, pin: pin, binaryRelPath: privateBinaryName, usesHold: true,
            directoryName: { p in "\(sanitize(p.version))-\(p.archiveSHA256.prefix(12))" },
            stage: { payload, progress in try await stageAgentMail(pin: pin, payload: payload, progress: progress) },
            postProbe: { journal in await postPublicationProbe(journal) },
            validateExtra: nil, stagesInPlace: false)
    }

    static func sanitize(_ v: String) -> String {
        let s = v.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" }
        return s.isEmpty ? "unknown" : s
    }

    /// Download (or the dev fixture), verify the compiled archive hash,
    /// extract, unquarantine, then the STAGED probe: the staged binary itself
    /// with a placeholder key (§7.9.2 v23; never through `current`).
    static func stageAgentMail(pin: RuntimePin, payload: URL, progress: (@Sendable (String) -> Void)?) async throws -> [String: String]? {
        let archive: Data
        if let fixture = RuntimeSeams.env("BRIGLIA_AGENTMAIL_TEST_ARCHIVE") {
            archive = try Data(contentsOf: URL(fileURLWithPath: fixture))
        } else {
            guard let asset = pinnedAsset(triple: pin.triple) else {
                throw RuntimeError("no pinned AgentMail CLI build for this platform (\(pin.triple))")
            }
            do {
                archive = try await ProcessRunner.downloadReportingProgress(
                    from: asset.url, label: "Downloading the agentmail CLI \(pin.version)", progress: progress)
            } catch {
                throw RuntimeError("download of \(asset.asset) failed (\(error.localizedDescription))")
            }
        }
        guard RuntimeFS.sha256(archive) == pin.archiveSHA256 else {
            throw RuntimeError("checksum mismatch: the download is not the pinned AgentMail \(pin.version) archive")
        }
        let staging = payload.deletingLastPathComponent()
        let archivePath = staging.appendingPathComponent("agentmail.tar.gz")
        try RuntimeFS.write(archive, to: archivePath, mode: 0o600)
        try RuntimeFS.ensureDir(payload)
        progress?("Extracting the agentmail CLI…")
        let untar = await RuntimeProcess.run("/usr/bin/tar", ["-xf", archivePath.path, "-C", payload.path, "--strip-components=1"], timeout: 60)
        guard untar.status == 0 else { throw RuntimeError("extraction failed: \(RuntimeProcess.detail(untar))") }
        try? FileManager.default.removeItem(at: archivePath)
        let extracted = payload.appendingPathComponent("agentmail")
        guard RuntimeFS.kind(extracted.path) == .regular else { throw RuntimeError("archive did not contain the agentmail binary") }
        // Only the binary is kept (the archive's README/LICENSE are not needed).
        let binary = payload.appendingPathComponent(privateBinaryName)
        guard rename(extracted.path, binary.path) == 0 else { throw RuntimeError("could not place the binary: \(String(cString: strerror(errno)))") }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: payload.path)) ?? [] where name != privateBinaryName {
            try? FileManager.default.removeItem(at: payload.appendingPathComponent(name))
        }
        chmod(binary.path, 0o700)
        #if os(macOS)
        if removexattr(binary.path, "com.apple.quarantine", 0) != 0, errno != ENOATTR {
            throw RuntimeError("could not remove the quarantine attribute: \(String(cString: strerror(errno)))")
        }
        #endif
        var env = probeEnvironment()
        env["AGENTMAIL_API_KEY"] = probePlaceholderKey
        let probe = await RuntimeProcess.run(binary.path, ["--version"], env: env, timeout: PrivateRuntimeEngine.probeTimeout)
        guard probe.status == 0 else { throw RuntimeError("the downloaded binary failed to run: \(RuntimeProcess.detail(probe))") }
        guard probe.stdout.contains(pin.version) else {
            throw RuntimeError("the downloaded binary reports \(probe.stdout.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)), not \(pin.version)")
        }
        return nil
    }

    /// A clean, credential-free child environment for probes.
    static func probeEnvironment() -> [String: String] {
        let base = ProcessInfo.processInfo.environment
        var env: [String: String] = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": base["HOME"] ?? NSHomeDirectory()]
        for k in ["TMPDIR", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "CFFIXED_USER_HOME", "LANG",
                  AssistantProfile.environmentKey, AssistantProfile.experimentalKey] { if let v = base[k] { env[k] = v } }
        return env
    }

    /// Post-publication probe through the published wrapper in the
    /// journal-bound probe mode (§7.9.2 v23).
    static func postPublicationProbe(_ journal: RuntimeJournal) async -> String? {
        do { try ensureWrapper() } catch { return "the wrapper could not be written: \(error)" }
        var env = probeEnvironment()
        env["BRIGLIA_AGENTMAIL_PROBE"] = journal.attemptId
        env["AGENTMAIL_API_KEY"] = "caller-key-ignored-in-probe-mode"
        let r = await RuntimeProcess.run(wrapperURL.path, ["--version"], env: env, timeout: PrivateRuntimeEngine.probeTimeout)
        guard r.status == 0 else { return RuntimeProcess.detail(r) }
        guard r.stdout.contains(journal.newRecord.version) else { return "reports \(r.stdout.prefix(60)), not \(journal.newRecord.version)" }
        return nil
    }

    // MARK: The wrapper

    static func wrapperScript(brigliaPath: String) -> String {
        """
        #!/bin/sh
        # Installed by Briglia CLI. Runs Briglia's private AgentMail CLI after
        # checking it against its install receipt; the key is fetched at exec
        # time and handed only to that binary.
        exec \(RuntimeFS.shellQuote(brigliaPath))\(RuntimeFS.profileWords()) __agentmail-exec "$@"
        """ + "\n"
    }

    /// Writes the Briglia-only wrapper when its expected bytes differ
    /// (private validated write; never anything in ~/.local/bin).
    static func ensureWrapper() throws {
        let bytes = Data(wrapperScript(brigliaPath: brigliaPath()).utf8)
        if RuntimeFS.kind(wrapperURL.path) == .regular, (try? Data(contentsOf: wrapperURL)) == bytes,
           FileManager.default.isExecutableFile(atPath: wrapperURL.path) { return }
        try RuntimeFS.ensureDir(RuntimePaths.binDir)
        switch RuntimeFS.kind(wrapperURL.path) {
        case .absent, .regular: break
        default: throw RuntimeError("\(wrapperURL.path) exists and is not a regular file — refusing")
        }
        try RuntimeFS.write(bytes, to: wrapperURL, mode: 0o700)
    }

    /// Content check for a broker wrapper (ours or an older Briglia's).
    static func isBrokerWrapper(at url: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: url.path),
              let data = try? Data(contentsOf: url),
              data.count < 4096,
              let text = String(data: data, encoding: .utf8) else { return false }
        return text.hasPrefix("#!/bin/sh") && (text.contains("__agentmail-key") || text.contains("__agentmail-exec"))
    }

    /// The legacy broker wrapper shape (pre-Phase 1), kept for the migration
    /// selftests and the legacy inspection.
    static func legacyWrapperScript(adaPath: String, realBinaryPath: String) -> String {
        """
        #!/bin/sh
        # Installed by Briglia CLI. Launches the AgentMail CLI with Briglia's stored
        # API key fetched at exec time, so the key never rides ambiently in
        # other processes' environments.
        if [ -z "${AGENTMAIL_API_KEY:-}" ]; then
            AGENTMAIL_API_KEY="$('\(adaPath)' __agentmail-key 2>/dev/null || true)"
            export AGENTMAIL_API_KEY
        fi
        exec '\(realBinaryPath)' "$@"
        """
    }

    // MARK: Per-use validation (`__agentmail-exec`)

    enum ExecDecision: Equatable {
        /// Run this binary; `forcedKey` replaces any caller key (probe mode).
        case run(binary: String, forcedKey: String?)
        case refuse(String)
    }

    /// Lock-free, read-only: the files are replaced atomically by writers.
    static func execDecision(args: [String], environment: [String: String]) -> ExecDecision {
        let c = RuntimeComponent.agentmail
        let sel = RuntimeSelectionStore.peek()
        guard let sel else { return .refuse(offMessage("Briglia's runtime state is unreadable")) }
        let hold = sel[c].hold
        let receipt: RuntimeReceipt?
        do { receipt = try RuntimeFS.readJSON(RuntimeReceipt.self, RuntimePaths.receipt(c)) } catch {
            return .refuse(offMessage("its install receipt is unreadable"))
        }
        let cur = PrivateRuntimeEngine.currentState(c)
        func binary(_ rec: RuntimeRecord) -> String {
            RuntimePaths.dir(c).appendingPathComponent(rec.directory).appendingPathComponent(privateBinaryName).path
        }
        func intact(_ rec: RuntimeRecord) -> Bool {
            RuntimeFS.validVersionRef(rec.directory)
                && (try? RuntimeFS.contain(RuntimePaths.current(c), finalMayBeSymlink: true)) != nil
                && (try? RuntimeFS.contain(URL(fileURLWithPath: binary(rec)))) != nil
                && RuntimeFS.sha256(file: URL(fileURLWithPath: binary(rec))) == rec.binarySHA256
        }
        if let probeAttempt = environment["BRIGLIA_AGENTMAIL_PROBE"], !probeAttempt.isEmpty {
            guard args == ["--version"] else { return .refuse("probe mode allows only --version") }
            guard let j = try? RuntimeFS.readJSON(RuntimeJournal.self, RuntimePaths.journal(c)),
                  j.state == "committing", j.attemptId == probeAttempt, cur == .ref(j.newTarget),
                  j.newRecord.directory == j.newTarget, intact(j.newRecord) else {
                return .refuse("probe refused: no matching install in progress")
            }
            if let hold, hold.attemptId != probeAttempt { return .refuse(offMessage(holdText(hold))) }
            return .run(binary: binary(j.newRecord), forcedKey: probePlaceholderKey)
        }
        if let hold { return .refuse(offMessage(holdText(hold))) }
        guard let v = receipt?.verifiedRecord else {
            return .refuse("the AgentMail CLI is not installed for Briglia yet — choose AgentMail in `briglia menu`, or run `briglia agentmail upgrade`")
        }
        guard cur == .ref(v.directory), intact(v) else {
            return .refuse(offMessage("the install does not match its receipt"))
        }
        return .run(binary: binary(v), forcedKey: nil)
    }

    static func holdText(_ h: RuntimeHold) -> String {
        switch h.reason {
        case "repair-failed": return "repair failed"
        case "repair-interrupted": return "repair interrupted"
        case "repair-in-progress": return "a repair is in progress"
        default: return "the install does not match its receipt"
        }
    }

    static func offMessage(_ why: String) -> String {
        "AgentMail is off: \(why); run `briglia agentmail repair` (with Briglia stopped: `briglia service stop` or quit the terminal session)"
    }

    // MARK: Status used by setup, doctor, the menu and the prompt

    /// A usable private install (validated `verified`, no hold).
    static func agentMailBrokerInstalled() -> Bool {
        if case .run = execDecision(args: [], environment: [:]) { return true }
        return false
    }

    /// The version the agent will run: the verified private copy, else (while
    /// none exists yet) an older Briglia's wrapper in ~/.local/bin read
    /// inspect-only (§7.9.2); nil when neither.
    static func installedCLIVersion() -> String? {
        if let v = (try? RuntimeFS.readJSON(RuntimeReceipt.self, RuntimePaths.receipt(.agentmail)))??.verifiedRecord?.version,
           agentMailBrokerInstalled() {
            return v
        }
        return legacyInstalledVersion()
    }

    /// Inspect-only read of an older Briglia's ~/.local/bin pair.
    static func legacyInstalledVersion() -> String? {
        let w = legacyWrapperURL
        guard RuntimeFS.kind(w.path) == .regular, isBrokerWrapper(at: w),
              let data = try? Data(contentsOf: w), let target = legacyWrapperTarget(data),
              RuntimeFS.kind(target) == .regular else { return nil }
        return cliVersion(fromTargetBasename: URL(fileURLWithPath: target).lastPathComponent)
    }

    static func legacyWrapperTarget(_ bytes: Data) -> String? {
        guard let text = String(data: bytes, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("exec '") else { continue }
            let rest = t.dropFirst("exec '".count)
            guard let end = rest.firstIndex(of: "'") else { return nil }
            return String(rest[..<end])
        }
        return nil
    }

    static func cliVersion(fromTargetBasename base: String) -> String? {
        if base == legacyBinaryName { return "legacy" }
        guard base.hasPrefix(legacyBinaryName + "-") else { return nil }
        let rest = base.dropFirst(legacyBinaryName.count + 1)          // "<version>-<sha12>"
        guard let dash = rest.lastIndex(of: "-"), dash > rest.startIndex else { return nil }
        return String(rest[..<dash])
    }

    /// Command syntax of the CLI the agent runs. The Go CLI (0.x) used colon
    /// resources (`inboxes:messages list`); the Rust rewrite (1.x, pinned)
    /// uses nested subcommands (`inboxes messages list`) with the same flags.
    enum CLISyntax: Equatable { case v0Colon, v1Nested }

    static func cliSyntax(forInstalledVersion version: String?) -> CLISyntax {
        guard let version else { return .v1Nested }          // not installed: a fresh install gets the pinned 1.x
        if version == "legacy" { return .v0Colon }
        let major = Int(version.split(separator: ".").first ?? "") ?? 1
        return major == 0 ? .v0Colon : .v1Nested
    }

    /// Selftest seam.
    nonisolated(unsafe) static var cliSyntaxOverrideForTesting: CLISyntax?
    static var cliSyntax: CLISyntax { cliSyntaxOverrideForTesting ?? cliSyntax(forInstalledVersion: installedCLIVersion()) }
    /// `inboxes:messages` or `inboxes messages`, for prompt examples.
    static var messagesResource: String { cliSyntax == .v0Colon ? "inboxes:messages" : "inboxes messages" }

    /// Legacy ~/.local/bin findings (inspect-only, §7.8.1 step 2).
    static func legacyFindings() -> [String] {
        var out: [String] = []
        let dir = legacyDirectory
        let w = legacyWrapperURL
        switch RuntimeFS.kind(w.path) {
        case .absent: break
        case .regular:
            if isBrokerWrapper(at: w), let data = try? Data(contentsOf: w), let t = legacyWrapperTarget(data),
               URL(fileURLWithPath: t).deletingLastPathComponent().standardizedFileURL.path == dir.standardizedFileURL.path,
               RuntimeFS.kind(t) == .regular {
                out.append("old Briglia copy of agentmail left in place at \(w.path) (not used by Briglia any more); remove it with: rm '\(w.path)' '\(t)'")
            } else {
                out.append("another agentmail at \(w.path) (not Briglia's; Briglia never changes it)")
            }
        default:
            out.append("another agentmail entry at \(w.path) (not a regular file; Briglia never changes it)")
        }
        let tx = dir.appendingPathComponent(legacyTransactionFileName)
        if RuntimeFS.kind(tx.path) != .absent {
            let state = (try? JSONSerialization.jsonObject(with: Data(contentsOf: tx)) as? [String: Any])?["state"] as? String ?? "unknown"
            out.append("an interrupted older AgentMail install was left in \(dir.path) (state \(state)); Briglia no longer settles it — remove \(tx.path) and the agentmail-bin* files there by hand if you do not need them")
        }
        for path in foreignAgentMailInstalls() { out.append("another agentmail at \(path) (no access to Briglia's key; Briglia's own copy is used first)") }
        return out
    }

    /// Foreign `agentmail` executables on the standard prefix dirs.
    static func foreignAgentMailInstalls() -> [String] {
        ["/opt/homebrew/bin/agentmail", "/usr/local/bin/agentmail", "/usr/bin/agentmail"]
            .filter { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: Entry points

    /// Setup paths (wizard, setup-api, menu job): a first private install, or
    /// nil when one already works. Returns a human-readable failure.
    static func installAgentMailBinary(progress: (@Sendable (String) -> Void)? = nil) async -> String? {
        guard let pin = runtimePin else { return "no pinned AgentMail CLI build for this platform (\(currentTargetTriple))" }
        switch await PrivateRuntimeEngine.converge(runtimeSpec(pin: pin), trigger: .install, idle: nil, progress: progress) {
        case .upToDate, .converged:
            do { try ensureWrapper() } catch { return "installed, but the wrapper could not be written: \(error)" }
            return nil
        case .held(let h): return offMessage(holdText(h))
        case .failed(let why), .abandoned(let why), .throttled(let why), .busy(let why), .notApplicable(let why): return why
        }
    }

    /// Daemon startup (§7.8.1, §7.9.5): recovery, then convergence or the one
    /// automatic repair for a new pin. Only with the AgentMail provider.
    static func startupConvergence(idle: RuntimeIdleGate?, log: @escaping @Sendable (String) -> Void) async {
        guard let pin = runtimePin else { return }
        let spec = runtimeSpec(pin: pin)
        let health = await PrivateRuntimeEngine.recover(spec)
        try? ensureWrapperIfInstalled()
        guard EmailCalendarProvider.current == .agentmail else { return }
        if case .held(let hold) = health {
            if hold.pin != pin {
                let r = await AgentMailRepair.run(spec: spec, automatic: true, idle: idle)
                log("agentmail: automatic repair for the new pin \(pin.version): \(r)")
            } else {
                log("agentmail: off (\(holdText(hold))); waiting for `briglia agentmail repair`")
            }
            return
        }
        if case .notInstalled = health, legacyInstalledVersion() == nil {
            return   // never installed for Briglia: setup installs it, startup does not
        }
        let outcome = await PrivateRuntimeEngine.converge(spec, trigger: .auto, idle: idle)
        if case .converged = outcome { try? ensureWrapper() }
        log("agentmail: \(outcome)")
        for line in PrivateRuntimeEngine.collectGarbage(spec) { log("agentmail: \(line)") }
    }

    static func ensureWrapperIfInstalled() throws {
        if (try? RuntimeFS.readJSON(RuntimeReceipt.self, RuntimePaths.receipt(.agentmail)))??.verified != nil {
            try ensureWrapper()
        }
    }

    /// /deleteuserdata (§7.8.1 step 10): the private AgentMail directories,
    /// receipt, journal and hold go with the provider data; never ~/.local/bin.
    static func wipePrivateInstall() throws {
        let locks = try RuntimeLocks.take(.agentmail)
        defer { locks.release() }
        var (sel, _) = try RuntimeSelectionStore.load()
        sel.generation += 1
        sel[.agentmail] = RuntimeComponentState()
        try RuntimeSelectionStore.save(sel)
        let dir = RuntimePaths.dir(.agentmail)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where name != ".agentmail.lock" {
            try FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
        try? RuntimeFS.remove(wrapperURL)
        try PrivateStorage.fsyncDirectory(dir.path)
    }
}
