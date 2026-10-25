import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Node.js for Briglia's own features (security plan v24 §7.9.3). Owner
/// rules: a user's working Node at least as new as the pin is used and never
/// touched; otherwise Briglia keeps a PRIVATE pinned copy under
/// ~/.local/share/briglia/runtime/node/ used by full path only by its own
/// features (the managed Playwright MCP). ~/.local/node and ~/.local/bin are
/// never written. Fresh installs get the latest patched LTS (the pin below,
/// gated by scripts/pin_gate.py at every release).
enum NodeRuntime {
    static let pinnedVersion = "24.22.1"
    /// nodejs.org `node-v<ver>-<platform>.tar.gz` SHA-256 (Briglia's own
    /// record; SHASUMS256.txt is never fetched).
    static let pinnedArchiveSHA256: [String: String] = [
        "darwin-arm64": "89c682593d76cd44233fa53b1563264e7de9cbb189cad169135c5b4fadfbc0a7",
        "darwin-x64":   "d132557e7ee2b85af08b0c8c34338e65c6430f2238d01f727728ef42dc83b035",
        "linux-arm64":  "33c37be234ba8bee041961047b19160f4d7d0f164e8e246f78bdd10feff148b3",
        "linux-x64":    "eb6728e77c576a35162c122c45ccadf224d89ff00abc8dae46cc2897c6002d7c",
    ]

    static var platform: String {
        #if os(Linux)
        #if arch(arm64)
        return "linux-arm64"
        #else
        return "linux-x64"
        #endif
        #else
        #if arch(arm64)
        return "darwin-arm64"
        #else
        return "darwin-x64"
        #endif
        #endif
    }

    static var runtimePin: RuntimePin? {
        if let sha = RuntimeSeams.env("BRIGLIA_NODE_TEST_SHA256"), let v = RuntimeSeams.env("BRIGLIA_NODE_TEST_VERSION") {
            return RuntimePin(triple: platform, version: v, archiveSHA256: sha)
        }
        guard let sha = pinnedArchiveSHA256[platform] else { return nil }
        return RuntimePin(triple: platform, version: pinnedVersion, archiveSHA256: sha)
    }

    static func spec(pin: RuntimePin) -> RuntimeSpec {
        RuntimeSpec(
            component: .node, pin: pin, binaryRelPath: "bin/node", usesHold: false,
            directoryName: { p in "\(p.version)-\(p.archiveSHA256.prefix(12))" },
            stage: { payload, progress in try await stage(pin: pin, payload: payload, progress: progress) },
            postProbe: { j in await probe(directory: RuntimePaths.current(.node), version: j.newRecord.version) },
            validateExtra: nil, stagesInPlace: false)
    }

    static func stage(pin: RuntimePin, payload: URL, progress: (@Sendable (String) -> Void)?) async throws -> [String: String]? {
        let archive: Data
        if let fixture = RuntimeSeams.env("BRIGLIA_NODE_TEST_ARCHIVE") {
            archive = try Data(contentsOf: URL(fileURLWithPath: fixture))
        } else {
            let file = "node-v\(pin.version)-\(pin.triple).tar.gz"
            guard let url = URL(string: "https://nodejs.org/dist/v\(pin.version)/\(file)") else { throw RuntimeError("malformed Node URL") }
            do {
                archive = try await ProcessRunner.downloadReportingProgress(from: url, label: "Downloading Node.js \(pin.version)", progress: progress)
            } catch {
                throw RuntimeError("download of \(file) failed (\(error.localizedDescription))")
            }
        }
        guard RuntimeFS.sha256(archive) == pin.archiveSHA256 else {
            throw RuntimeError("checksum mismatch: the download is not the pinned Node.js \(pin.version) archive")
        }
        let staging = payload.deletingLastPathComponent()
        let tarball = staging.appendingPathComponent("node.tar.gz")
        let extract = staging.appendingPathComponent("extract", isDirectory: true)
        try PrivateStorage.writeAtomically(archive, to: tarball, mode: 0o600)
        try PrivateStorage.ensureDirectory(extract)
        progress?("Installing Node.js \(pin.version) for Briglia…")
        let untar = await RuntimeProcess.run("/usr/bin/tar", ["-xzf", tarball.path, "-C", extract.path], timeout: 300)
        guard untar.status == 0 else { throw RuntimeError("extraction failed: \(RuntimeProcess.detail(untar))") }
        try? FileManager.default.removeItem(at: tarball)
        let tops = ((try? FileManager.default.contentsOfDirectory(atPath: extract.path)) ?? []).filter { !$0.hasPrefix(".") }
        guard tops.count == 1, RuntimeFS.kind(extract.appendingPathComponent(tops[0]).path) == .directory else {
            throw RuntimeError("the archive does not contain exactly one Node.js directory")
        }
        guard rename(extract.appendingPathComponent(tops[0]).path, payload.path) == 0 else {
            throw RuntimeError("could not stage Node.js: \(String(cString: strerror(errno)))")
        }
        try? FileManager.default.removeItem(at: extract)
        #if os(macOS)
        _ = await RuntimeProcess.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", payload.path], timeout: 60)
        #endif
        if let why = await probe(directory: payload, version: pin.version) { throw RuntimeError("the downloaded Node.js failed its check: \(why)") }
        return nil
    }

    /// `bin/node --version` = the pin and a working `bin/npm`, with that
    /// directory first on PATH (so `#!/usr/bin/env node` tests this Node).
    static func probe(directory: URL, version: String) async -> String? {
        let bin = directory.appendingPathComponent("bin").path
        let env = ["PATH": "\(bin):/usr/bin:/bin", "HOME": NSHomeDirectory()]
        let n = await RuntimeProcess.run(bin + "/node", ["--version"], env: env, timeout: PrivateRuntimeEngine.probeTimeout)
        guard n.status == 0 else { return "node: \(RuntimeProcess.detail(n))" }
        guard n.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "v\(version)" else {
            return "node reports \(n.stdout.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)), not v\(version)"
        }
        let p = await RuntimeProcess.run(bin + "/npm", ["--version"], env: env, timeout: 60)
        guard p.status == 0, !p.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "npm: \(RuntimeProcess.detail(p))" }
        return nil
    }

    // MARK: Selection

    struct Candidate: Equatable { let node: String; let version: String }

    /// SemVer X.Y.Z → comparable tuple; nil for anything else (unknown).
    static func semver(_ s: String) -> [Int]? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let v = t.hasPrefix("v") ? String(t.dropFirst()) : t
        let parts = v.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let nums = parts.compactMap { Int($0) }
        return nums.count == 3 && parts.allSatisfy({ $0.allSatisfy(\.isNumber) && !$0.isEmpty }) ? nums : nil
    }

    static func atLeast(_ v: String, _ minimum: String) -> Bool? {
        guard let a = semver(v), let b = semver(minimum) else { return nil }
        return a.lexicographicallyPrecedes(b) ? false : true
    }

    /// Shared candidates in precedence order (v22, R21-4): every `node` on the
    /// inherited PATH, then the fixed locations; de-duplicated by resolved
    /// path; anything inside Briglia's data root excluded.
    static func sharedCandidatePaths(path: String? = ProcessInfo.processInfo.environment["PATH"]) -> [String] {
        let home = NSHomeDirectory()
        var dirs = (path ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty && $0.hasPrefix("/") }
        if let only = RuntimeSeams.env("BRIGLIA_NODE_TEST_SHARED_DIRS") {
            dirs = only.split(separator: ":").map(String.init)   // selftests: exactly these directories
        } else {
            dirs += ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "/usr/bin"]
        }
        let root = URL(fileURLWithPath: RuntimePaths.dataRoot.path).resolvingSymlinksInPath().path
        var seen = Set<String>(), out: [String] = []
        for d in dirs {
            let node = d + "/node"
            guard FileManager.default.isExecutableFile(atPath: node) else { continue }
            let real = URL(fileURLWithPath: node).resolvingSymlinksInPath().path
            if real == root || real.hasPrefix(root + "/") { continue }
            if seen.insert(real).inserted { out.append(node) }
        }
        return out
    }

    /// The first shared Node ≥ the pin whose npm works (never modified).
    static func acceptableShared(pin: RuntimePin, candidates: [String]) async -> (Candidate?, [String]) {
        var reasons: [String] = []
        for node in candidates {
            let dir = URL(fileURLWithPath: node).deletingLastPathComponent().path
            let env = ["PATH": "\(dir):/usr/bin:/bin", "HOME": NSHomeDirectory()]
            let r = await RuntimeProcess.run(node, ["--version"], env: env, timeout: 15)
            let v = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard r.status == 0, semver(v) != nil else { reasons.append("\(node): version unknown"); continue }
            guard atLeast(v, pin.version) == true else { reasons.append("\(node) is \(v), older than \(pin.version)"); continue }
            guard FileManager.default.isExecutableFile(atPath: dir + "/npm") else { reasons.append("\(node): no npm next to it"); continue }
            let n = await RuntimeProcess.run(dir + "/npm", ["--version"], env: env, timeout: 60)
            guard n.status == 0 else { reasons.append("\(dir)/npm does not run"); continue }
            return (Candidate(node: node, version: v), reasons)
        }
        return (nil, reasons)
    }

    struct Result: Equatable {
        /// Directory holding `node` and `npm` for Briglia's managed consumers.
        let directory: String?
        let providerClass: String
        let version: String?
        let reason: String?
    }

    /// Startup selection (before the managed Playwright bootstrap uses Node).
    static func select(trigger: RuntimeTrigger = .auto) async -> Result {
        guard let pin = runtimePin else {
            return record(Result(directory: nil, providerClass: "unavailable", version: nil, reason: "no pinned Node.js for \(platform)"))
        }
        let (shared, reasons) = await acceptableShared(pin: pin, candidates: sharedCandidatePaths())
        if let shared {
            removeShims()
            return record(Result(directory: URL(fileURLWithPath: shared.node).deletingLastPathComponent().path,
                                 providerClass: "shared-accepted", version: shared.version, reason: nil))
        }
        let spec = spec(pin: pin)
        let outcome = await PrivateRuntimeEngine.converge(spec, trigger: trigger)
        let why: String
        switch outcome {
        case .upToDate, .converged:
            let dir = RuntimePaths.current(.node).appendingPathComponent("bin").path
            do { try writeShims() } catch { NSLog("NodeRuntime: fallback shims not written: %@", "\(error)") }
            _ = PrivateRuntimeEngine.collectGarbage(spec, keepRunning: runningDirectories())
            return record(Result(directory: dir, providerClass: "private-exact", version: pin.version, reason: nil))
        case .failed(let w), .abandoned(let w), .throttled(let w), .busy(let w), .notApplicable(let w): why = w
        case .held: why = "held"
        }
        // A previously verified private copy that still validates keeps working
        // while an update to a new pin is throttled or failed.
        if case .ready(let r) = await PrivateRuntimeEngine.recover(spec) {
            try? writeShims()
            return record(Result(directory: RuntimePaths.current(.node).appendingPathComponent("bin").path,
                                 providerClass: "private-exact", version: r.version,
                                 reason: r.version == pin.version ? nil : "update to \(pin.version) pending: \(why)"))
        }
        removeShims()
        return record(Result(directory: nil, providerClass: "unavailable", version: nil,
                             reason: (reasons + ["private copy: \(why)"]).joined(separator: "; ")))
    }

    @discardableResult
    static func record(_ r: Result) -> Result {
        _ = try? RuntimeSelectionStore.update { sel in
            var st = sel[.node]
            st.selection = RuntimeSelection(providerClass: r.providerClass, path: r.directory, version: r.version,
                                            probedAt: Date(), reason: r.reason)
            sel[.node] = st
        }
        return r
    }

    /// The selection a managed consumer must use (persisted, so a spawn that
    /// races the startup selection uses the last one); nil = none.
    static func selectedNodeBinary() -> String? {
        guard let s = RuntimeSelectionStore.peek()?[.node].selection, ["private-exact", "shared-accepted"].contains(s.providerClass),
              let dir = s.path else { return nil }
        let node = dir + "/node"
        return FileManager.default.isExecutableFile(atPath: node) ? node : nil
    }

    // MARK: Running consumers (restart pending, §7.7)

    nonisolated(unsafe) private static var running: [Int32: String] = [:]
    private static let runningLock = NSLock()

    static func recordRunning(nodeBinary: String, pid: Int32) {
        let dir = URL(fileURLWithPath: nodeBinary).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent().path
        runningLock.lock(); running[pid] = dir; runningLock.unlock()
        _ = try? RuntimeSelectionStore.update { sel in
            var st = sel[.node]
            st.running = RuntimeRunning(resolvedDirectory: dir, pid: pid, startedAt: Date())
            sel[.node] = st
        }
    }

    static func runningDirectories() -> Set<String> {
        runningLock.lock(); defer { runningLock.unlock() }
        let root = RuntimePaths.dir(.node).resolvingSymlinksInPath().path + "/"
        return Set(running.values.compactMap { $0.hasPrefix(root) ? String($0.dropFirst(root.count)) : nil })
    }

    /// True while a running managed consumer uses another directory than the selection.
    static func restartPending() -> Bool {
        guard let sel = RuntimeSelectionStore.peek()?[.node], let run = sel.running, kill(run.pid, 0) == 0,
              let path = sel.selection?.path else { return false }
        let selected = URL(fileURLWithPath: path + "/node").resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().path
        return selected != run.resolvedDirectory
    }

    // MARK: Fallback shims (agent Bash and user MCP servers, LAST on PATH)

    static let shimNames = ["node", "npm", "npx"]

    static func writeShims() throws {
        try PrivateStorage.ensureDirectory(RuntimePaths.fallbackBinDir)
        for name in shimNames {
            let link = RuntimePaths.fallbackBinDir.appendingPathComponent(name)
            let target = RuntimePaths.current(.node).appendingPathComponent("bin/\(name)").path
            if RuntimeFS.readLink(link) == target { continue }
            switch RuntimeFS.kind(link.path) {
            case .absent, .symlink: try RuntimeFS.switchLink(link, to: target)
            default: throw RuntimeError("\(link.path) exists and is not a link — refusing")
            }
        }
    }

    static func removeShims() {
        for name in shimNames {
            let link = RuntimePaths.fallbackBinDir.appendingPathComponent(name)
            if RuntimeFS.kind(link.path) == .symlink { try? RuntimeFS.remove(link) }
        }
    }

    // MARK: Legacy (inspect-only)

    static var legacyRoot: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/node", isDirectory: true) }

    /// A legacy ~/.local/node (and its ~/.local/bin links) left in place.
    static func legacyFindings(selected: String?) -> [String] {
        guard RuntimeFS.kind(legacyRoot.path) == .directory else { return [] }
        let usedByBriglia = selected.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path.hasPrefix(legacyRoot.resolvingSymlinksInPath().path) } ?? false
        if usedByBriglia { return ["the Node.js in ~/.local/node (installed by an older Briglia) is new enough and is used as your own Node; Briglia never updates it"] }
        let links = ["node", "npm", "npx"].map { NSHomeDirectory() + "/.local/bin/" + $0 }.filter { RuntimeFS.kind($0) == .symlink }
        let rm = (["rm -rf '\(legacyRoot.path)'"] + links.map { "rm '\($0)'" }).joined(separator: "; ")
        return ["legacy Node.js copy left in place at \(legacyRoot.path), not used by Briglia; remove it with: \(rm)"]
    }
}
