import Foundation

/// Auto-discovery and injection of per-project instruction files
/// (AGENTS.md / CLAUDE.md), the cross-tool standard for repo-level agent
/// guidance (build/test commands, conventions, gotchas).
///
/// When a tool touches a path inside a project, every instruction file on the
/// way from the touched path up to the repository root is loaded once (root
/// first, nearest last, so a nested file refines the repo-wide one instead of
/// hiding it) and appended to that tool's result, the same way LSP
/// diagnostics ride on edit results. Loaded state is tracked per executor
/// (the main agent and each subagent context inject independently), keyed by
/// instruction-file path + mtime so an edited file re-injects automatically.
///
/// Deliberately NOT protected from context pruning: when the watermark pruner
/// drops the tool interaction carrying the instructions, it clears the
/// corresponding entry here (see ConversationManager.applyPrunePlan), and the
/// next tool touching that project re-injects them. Projects being actively
/// worked on re-load within one tool call; dormant projects fall out of
/// context entirely, so nothing accumulates across weeks of conversation.
final class ProjectInstructionsTracker: @unchecked Sendable {

    /// Checked in order; the first match in a directory wins.
    static let instructionFileNames = ["AGENTS.md", "CLAUDE.md"]

    /// Cap on injected instruction content (~5k tokens).
    static let maxContentLength = 20_000

    static let markerPrefix = "[PROJECT INSTRUCTIONS: "
    static let markerEnd = "[END PROJECT INSTRUCTIONS]"

    static let verificationMarkerPrefix = "[PROJECT VERIFICATION: "
    static let verificationMarkerEnd = "[END PROJECT VERIFICATION]"

    /// Tools whose arguments carry filesystem paths worth scanning.
    private static let pathAwareTools: Set<String> = [
        "read_file", "write_file", "edit_file", "apply_patch",
        "grep", "glob", "list_dir", "bash", "lsp"
    ]

    private let lock = NSLock()
    /// Instruction-file path → mtime at the moment it was injected into this
    /// executor's context.
    private var loaded: [String: Date] = [:]
    /// Project roots whose detected verification checks are already in context.
    private var verifiedRoots = Set<String>()

    // MARK: - Injection

    /// Returns a payload to append to the tool result when the touched project
    /// has an instruction file that is not yet in context (or has changed on
    /// disk since it was loaded). Returns nil when there is nothing new.
    func payload(toolName: String, argumentsJSON: String) -> String? {
        guard Self.pathAwareTools.contains(toolName) else { return nil }
        let touched = Self.touchedPaths(toolName: toolName, argumentsJSON: argumentsJSON)
        guard !touched.isEmpty else { return nil }

        let fm = FileManager.default
        var blocks: [String] = []
        var seenThisCall = Set<String>()

        for (path, fileURL) in touched.flatMap({ p in Self.instructionFiles(forTouchedPath: p).map { (p, $0) } }) {
            let filePath = fileURL.path
            guard !seenThisCall.contains(filePath) else { continue }
            seenThisCall.insert(filePath)

            guard let mtime = (try? fm.attributesOfItem(atPath: filePath))?[.modificationDate] as? Date else { continue }

            lock.lock()
            let alreadyCurrent = loaded[filePath] == mtime
            if !alreadyCurrent { loaded[filePath] = mtime }
            lock.unlock()
            if alreadyCurrent { continue }

            // The model is reading the instruction file directly — record it
            // as loaded but don't duplicate its content in the same result.
            if toolName == "read_file",
               URL(fileURLWithPath: path).standardizedFileURL.path == filePath {
                continue
            }

            guard var content = try? String(contentsOf: fileURL, encoding: .utf8) else {
                lock.lock(); loaded.removeValue(forKey: filePath); lock.unlock()
                continue
            }
            if content.count > Self.maxContentLength {
                content = String(content.prefix(Self.maxContentLength))
                    + "\n…[truncated — read \(filePath) for the rest]"
            }
            let root = fileURL.deletingLastPathComponent().path
            blocks.append(
                Self.markerPrefix + filePath + "]\n"
                + "Project instruction file auto-loaded — follow it for all work under \(root):\n\n"
                + content.trimmingCharacters(in: .whitespacesAndNewlines)
                + "\n" + Self.markerEnd
            )
        }

        guard !blocks.isEmpty else { return nil }
        return "\n\n" + blocks.joined(separator: "\n\n")
    }

    /// Pruner callback: the tool interaction carrying this instruction file
    /// left the context, so the next touch of that project must re-inject.
    func clearLoaded(instructionFilePath: String) {
        lock.lock()
        loaded.removeValue(forKey: instructionFilePath)
        lock.unlock()
    }

    /// Scans a tool-result content string for injected instruction markers and
    /// returns the instruction-file paths it carried.
    static func markerPaths(in content: String) -> [String] {
        bracketedPaths(in: content, prefix: markerPrefix)
    }

    // MARK: - Verification checks

    /// Tools whose success means project code changed on disk.
    private static let editTools: Set<String> = ["write_file", "edit_file", "apply_patch"]

    /// Returns a payload describing the project's detected build/test/typecheck
    /// commands the first time a successful code edit lands in that project.
    /// Detection is manifest-based (Package.swift, package.json, Cargo.toml,
    /// go.mod, Makefile, *.xcodeproj, …); AGENTS.md remains authoritative when
    /// it declares different commands.
    func verificationPayload(toolName: String, argumentsJSON: String, resultContent: String) -> String? {
        guard Self.editTools.contains(toolName) else { return nil }
        guard resultContent.contains("\"success\":true") else { return nil }
        let touched = Self.touchedPaths(toolName: toolName, argumentsJSON: argumentsJSON)
        guard !touched.isEmpty else { return nil }

        var blocks: [String] = []
        for path in touched {
            guard let root = Self.verificationRoot(forTouchedPath: path) else { continue }
            let rootPath = root.path

            lock.lock()
            let inserted = verifiedRoots.insert(rootPath).inserted
            lock.unlock()
            guard inserted else { continue }

            let checks = Self.detectChecks(inProjectRoot: root)
            guard !checks.isEmpty else { continue }

            blocks.append(
                Self.verificationMarkerPrefix + rootPath + "]\n"
                + "Detected checks for this project. After completing your edits here, run the narrowest applicable one before reporting done (commands declared in the project's AGENTS.md take precedence):\n"
                + checks.map { "- " + $0 }.joined(separator: "\n")
                + "\n" + Self.verificationMarkerEnd
            )
        }

        guard !blocks.isEmpty else { return nil }
        return "\n\n" + blocks.joined(separator: "\n\n")
    }

    /// Pruner callback for verification blocks, mirroring clearLoaded.
    func clearVerification(root: String) {
        lock.lock()
        verifiedRoots.remove(root)
        lock.unlock()
    }

    /// Scans a tool-result content string for injected verification markers
    /// and returns the project roots they carried.
    static func verificationMarkerRoots(in content: String) -> [String] {
        bracketedPaths(in: content, prefix: verificationMarkerPrefix)
    }

    private static func bracketedPaths(in content: String, prefix: String) -> [String] {
        guard content.contains(prefix) else { return [] }
        var paths: [String] = []
        var searchRange = content.startIndex..<content.endIndex
        while let prefixRange = content.range(of: prefix, range: searchRange) {
            guard let closing = content.range(of: "]", range: prefixRange.upperBound..<content.endIndex) else { break }
            let path = String(content[prefixRange.upperBound..<closing.lowerBound])
            if path.hasPrefix("/") { paths.append(path) }
            searchRange = closing.upperBound..<content.endIndex
        }
        return paths
    }

    /// Manifest files that mark a directory as a verifiable project root.
    private static let manifestNames: Set<String> = [
        "Package.swift", "package.json", "tsconfig.json", "Cargo.toml",
        "go.mod", "pyproject.toml", "setup.py", "pytest.ini", "tox.ini",
        "Makefile", "build.gradle", "build.gradle.kts", "pom.xml"
    ]

    /// Walks up from a touched path to the nearest directory containing a
    /// recognized build/test manifest. Same boundaries as instructionFile:
    /// stops after the repo root (.git), never home or filesystem root.
    static func verificationRoot(forTouchedPath path: String) -> URL? {
        let fm = FileManager.default
        let standardized = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL

        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: standardized.path, isDirectory: &isDir)
        var dir = (exists && isDir.boolValue) ? standardized : standardized.deletingLastPathComponent()

        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL.path

        for _ in 0..<64 {
            let dirPath = dir.path
            if dirPath == "/" || dirPath == home { break }

            if let entries = try? fm.contentsOfDirectory(atPath: dirPath) {
                if entries.contains(where: { Self.manifestNames.contains($0) || $0.hasSuffix(".xcodeproj") }) {
                    return dir
                }
                // Repo root with no manifest anywhere below — stop the walk.
                if entries.contains(".git") { break }
            }

            let parent = dir.deletingLastPathComponent()
            if parent.path == dirPath { break }
            dir = parent
        }
        return nil
    }

    /// Builds "kind: command" lines from the manifests present at the root.
    /// Ordered narrowest-first (typecheck → test → build) where possible.
    static func detectChecks(inProjectRoot root: URL) -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        let set = Set(entries)
        var checks: [String] = []

        if set.contains("Package.swift") {
            checks.append("build: swift build")
            checks.append("test: swift test")
        }
        if let xcodeproj = entries.first(where: { $0.hasSuffix(".xcodeproj") }), !set.contains("Package.swift") {
            let name = (xcodeproj as NSString).deletingPathExtension
            checks.append("build: xcodebuild -scheme \(name) -configuration Debug build (confirm scheme with `xcodebuild -list`)")
        }
        if set.contains("package.json"),
           let data = try? Data(contentsOf: root.appendingPathComponent("package.json")),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let runner = set.contains("bun.lockb") || set.contains("bun.lock") ? "bun run"
                : set.contains("pnpm-lock.yaml") ? "pnpm run"
                : set.contains("yarn.lock") ? "yarn"
                : "npm run"
            let scripts = (obj["scripts"] as? [String: Any]) ?? [:]
            for key in ["typecheck", "test", "build", "lint"] where scripts[key] != nil {
                checks.append("\(key): \(runner) \(key)")
            }
        }
        if set.contains("tsconfig.json") {
            checks.append("typecheck: npx tsc --noEmit")
        }
        if set.contains("Cargo.toml") {
            checks.append("typecheck: cargo check")
            checks.append("test: cargo test")
        }
        if set.contains("go.mod") {
            checks.append("build: go build ./...")
            checks.append("test: go test ./...")
        }
        if set.contains("pytest.ini") || set.contains("tox.ini")
            || ((set.contains("pyproject.toml") || set.contains("setup.py")) && set.contains("tests")) {
            checks.append("test: python3 -m pytest")
        }
        if set.contains("Makefile"),
           let makefile = try? String(contentsOf: root.appendingPathComponent("Makefile"), encoding: .utf8) {
            let lines = makefile.split(separator: "\n", omittingEmptySubsequences: true)
            for target in ["test", "build", "check", "lint"] {
                if lines.contains(where: { $0.hasPrefix("\(target):") }) {
                    checks.append("\(target): make \(target)")
                }
            }
        }
        if set.contains("build.gradle") || set.contains("build.gradle.kts") {
            let gradle = set.contains("gradlew") ? "./gradlew" : "gradle"
            checks.append("build: \(gradle) build")
            checks.append("test: \(gradle) test")
        }
        if set.contains("pom.xml") {
            checks.append("test: mvn -q test")
        }

        if checks.count > 8 { checks = Array(checks.prefix(8)) }
        return checks
    }

    // MARK: - Discovery

    /// Every instruction file from the repository root down to the touched
    /// path, root first and nearest last (at most one per directory). Stops at
    /// the repository root (a directory containing .git) and never treats the
    /// home directory or filesystem root as a project.
    static func instructionFiles(forTouchedPath path: String) -> [URL] {
        let fm = FileManager.default
        let standardized = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL

        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: standardized.path, isDirectory: &isDir)
        var dir = (exists && isDir.boolValue) ? standardized : standardized.deletingLastPathComponent()

        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL.path
        var nearestFirst: [URL] = []

        for _ in 0..<64 {
            let dirPath = dir.path
            if dirPath == "/" || dirPath == home { break }

            for name in instructionFileNames {
                let candidate = dir.appendingPathComponent(name)
                var candidateIsDir: ObjCBool = false
                if fm.fileExists(atPath: candidate.path, isDirectory: &candidateIsDir), !candidateIsDir.boolValue {
                    nearestFirst.append(candidate)
                    break
                }
            }

            // Repo root reached — don't escape into parent directories above the repo.
            if fm.fileExists(atPath: dir.appendingPathComponent(".git").path) { break }

            let parent = dir.deletingLastPathComponent()
            if parent.path == dirPath { break }
            dir = parent
        }
        return nearestFirst.reversed()
    }

    /// Extracts candidate filesystem paths from a tool call's arguments.
    static func touchedPaths(toolName: String, argumentsJSON: String) -> [String] {
        guard let data = argumentsJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        var paths: [String] = []
        if toolName == "apply_patch" {
            if let patchText = obj["patch_text"] as? String {
                for line in patchText.split(separator: "\n", omittingEmptySubsequences: true) {
                    for prefix in ["*** Update File: ", "*** Add File: ", "*** Delete File: ", "*** Move to: "] {
                        if line.hasPrefix(prefix) {
                            paths.append(String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces))
                            break
                        }
                    }
                }
            }
        } else if toolName == "bash" {
            if let workdir = obj["workdir"] as? String { paths.append(workdir) }
        } else {
            if let path = obj["path"] as? String { paths.append(path) }
        }

        return paths.filter { $0.hasPrefix("/") || $0.hasPrefix("~") }
    }
}

/// The context-marker blocks (project instructions, verification checks, git
/// checkpoints) carried by the tool results of one context: rounds still
/// pending plus rounds embedded in completed replies. Only tool results are
/// scanned; a summary that quotes a marker line does not carry the block.
///
/// Every path that removes tool results without going through the main
/// pruner (subagent compaction, emergency summarization, the oversized-batch
/// cutoff) compares the context before and after and releases the markers
/// that left, so the next touch of that project re-injects them. A marker
/// still carried by a retained result stays loaded.
struct InjectedContextMarkers: Equatable {
    var instructionFiles = Set<String>()
    var verificationRoots = Set<String>()
    var checkpointRoots = Set<String>()

    init() {}

    init(messages: [Message], interactions: [ToolInteraction]) {
        for message in messages { for round in message.toolInteractions { add(round) } }
        for round in interactions { add(round) }
    }

    mutating func add(_ round: ToolInteraction) {
        for result in round.results {
            instructionFiles.formUnion(ProjectInstructionsTracker.markerPaths(in: result.content))
            verificationRoots.formUnion(ProjectInstructionsTracker.verificationMarkerRoots(in: result.content))
            checkpointRoots.formUnion(GitCheckpointTracker.markerRoots(in: result.content))
        }
    }

    var isEmpty: Bool { instructionFiles.isEmpty && verificationRoots.isEmpty && checkpointRoots.isEmpty }

    /// Markers present here and absent from `retained`.
    func removing(_ retained: InjectedContextMarkers) -> InjectedContextMarkers {
        var left = InjectedContextMarkers()
        left.instructionFiles = instructionFiles.subtracting(retained.instructionFiles)
        left.verificationRoots = verificationRoots.subtracting(retained.verificationRoots)
        left.checkpointRoots = checkpointRoots.subtracting(retained.checkpointRoots)
        return left
    }
}
