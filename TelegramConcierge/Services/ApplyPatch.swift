import Foundation

/// Codex-style `apply_patch` implementation.
///
/// Supported envelope:
///
///   *** Begin Patch
///   *** Update File: <path>
///   @@ optional anchor
///    context line
///   -removed line
///   +added line
///   *** Add File: <path>
///   +added content line
///   *** Delete File: <path>
///   *** End Patch
///
/// Multi-file operations are atomic: all hunks are parsed and validated against
/// current file contents before ANY write happens. If any hunk fails, no files are modified.
///
/// Limitations (acceptable for first pass):
/// - `*** Move to:` following an Update is supported (rename with in-flight update).
/// - Binary files are not supported.
/// - The parser is line-based and case-sensitive.
enum ApplyPatch {

    enum Operation {
        case update(path: String, hunks: [Hunk], moveTo: String?)
        case add(path: String, content: String)
        case delete(path: String)
    }

    struct Hunk {
        /// Zero or more context lines (optional but recommended).
        let context: [String]
        /// Optional `@@` anchor hint (e.g. a function signature) used to disambiguate.
        let anchor: String?
        /// Interleaved diff lines: each item is (kind, text).
        let diff: [(Kind, String)]

        enum Kind { case context, removed, added }
    }

    struct OpResult {
        let content: String
    }

    // MARK: - Entry point

    static func run(patchText: String) async -> OpResult {
        let operations: [Operation]
        do {
            operations = try parse(patchText: patchText)
        } catch let e as PatchError {
            return OpResult(content: jsonError("patch parse failed: \(e.message)"))
        } catch {
            return OpResult(content: jsonError("patch parse failed: \(error.localizedDescription)"))
        }

        // Phase 1: validate all operations can apply, producing the new content in-memory.
        var plans: [Plan] = []
        for op in operations {
            do {
                let plan = try await planOperation(op)
                plans.append(plan)
            } catch let e as PatchError {
                return OpResult(content: jsonError("patch cannot apply: \(e.message)"))
            } catch {
                return OpResult(content: jsonError("patch cannot apply: \(error.localizedDescription)"))
            }
        }

        // Phase 2: apply all plans. No rollback needed because we didn't touch disk yet.
        // If a disk write itself fails midway, we attempt to revert prior writes using pre-images.
        var applied: [(path: String, preImage: Data?)] = []
        var writtenFiles: [(path: String, oldText: String, newText: String)] = []
        for plan in plans {
            do {
                if let written = try await commitPlan(plan, applied: &applied) {
                    writtenFiles.append(written)
                }
            } catch let e as PatchError {
                // Attempt rollback.
                testHookBeforeRollback?()
                rollback(applied: applied)
                return OpResult(content: jsonError("patch apply failed mid-write: \(e.message). Rolled back any prior writes."))
            } catch {
                testHookBeforeRollback?()
                rollback(applied: applied)
                return OpResult(content: jsonError("patch apply failed mid-write: \(error.localizedDescription). Rolled back any prior writes."))
            }
        }

        let summary: [[String: Any]] = operations.map { op in
            switch op {
            case .update(let path, _, let moveTo):
                if let moveTo { return ["op": "update+move", "from": path, "to": moveTo] }
                return ["op": "update", "path": path]
            case .add(let path, _): return ["op": "add", "path": path]
            case .delete(let path): return ["op": "delete", "path": path]
            }
        }
        var result: [String: Any] = [
            "success": true,
            "files_affected": operations.count,
            "operations": summary
        ]
        if !writtenFiles.isEmpty {
            await LSPDiagnosticsReporter.attachBatch(
                to: &result,
                files: writtenFiles.map { (path: $0.path, text: $0.newText) }
            )
            // Attach per-file unified diff so the agent can verify what changed
            // without re-reading each file.
            var diffsByPath: [String: Any] = [:]
            for file in writtenFiles {
                if let diff = StageMarkers.measure("fs.diff", { DiffUtil.unifiedDiff(old: file.oldText, new: file.newText, path: file.path) }) {
                    diffsByPath[file.path] = diff
                }
            }
            if !diffsByPath.isEmpty {
                result["diffs_by_file"] = diffsByPath
            }
        }
        return OpResult(content: jsonString(result))
    }

    // MARK: - Parser

    struct PatchError: Error { let message: String }

    static func parse(patchText: String) throws -> [Operation] {
        let lines = patchText.components(separatedBy: "\n")
        var i = 0
        // Find "*** Begin Patch"
        while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("*** Begin Patch") {
            i += 1
        }
        if i == lines.count {
            throw PatchError(message: "missing '*** Begin Patch' header")
        }
        i += 1

        var ops: [Operation] = []
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("*** End Patch") { return ops }
            if trimmed.hasPrefix("*** Update File:") {
                let path = String(trimmed.dropFirst("*** Update File:".count)).trimmingCharacters(in: .whitespaces)
                i += 1
                var moveTo: String? = nil
                if i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("*** Move to:") {
                    moveTo = String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst("*** Move to:".count)).trimmingCharacters(in: .whitespaces)
                    i += 1
                }
                let hunks = try parseHunks(lines: lines, i: &i)
                ops.append(.update(path: FilesystemTools.normalizePath(path), hunks: hunks, moveTo: moveTo.map { FilesystemTools.normalizePath($0) }))
            } else if trimmed.hasPrefix("*** Add File:") {
                let path = String(trimmed.dropFirst("*** Add File:".count)).trimmingCharacters(in: .whitespaces)
                i += 1
                let content = try parseAddContent(lines: lines, i: &i)
                ops.append(.add(path: FilesystemTools.normalizePath(path), content: content))
            } else if trimmed.hasPrefix("*** Delete File:") {
                let path = String(trimmed.dropFirst("*** Delete File:".count)).trimmingCharacters(in: .whitespaces)
                i += 1
                ops.append(.delete(path: FilesystemTools.normalizePath(path)))
            } else if trimmed.isEmpty {
                i += 1
            } else {
                throw PatchError(message: "unexpected line at position \(i): '\(line)'")
            }
        }
        throw PatchError(message: "missing '*** End Patch' footer")
    }

    private static func parseHunks(lines: [String], i: inout Int) throws -> [Hunk] {
        var hunks: [Hunk] = []
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("*** Update File:")
                || trimmed.hasPrefix("*** Add File:")
                || trimmed.hasPrefix("*** Delete File:")
                || trimmed.hasPrefix("*** End Patch") {
                return hunks
            }

            var anchor: String? = nil
            if trimmed.hasPrefix("@@") {
                let anchorText = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                anchor = anchorText.isEmpty ? nil : anchorText
                i += 1
            }

            var diff: [(Hunk.Kind, String)] = []
            while i < lines.count {
                let ln = lines[i]
                let tr = ln.trimmingCharacters(in: .whitespaces)
                if tr.hasPrefix("@@")
                    || tr.hasPrefix("*** Update File:")
                    || tr.hasPrefix("*** Add File:")
                    || tr.hasPrefix("*** Delete File:")
                    || tr.hasPrefix("*** End Patch") {
                    break
                }
                if ln.hasPrefix("+") {
                    diff.append((.added, String(ln.dropFirst())))
                } else if ln.hasPrefix("-") {
                    diff.append((.removed, String(ln.dropFirst())))
                } else if ln.hasPrefix(" ") {
                    diff.append((.context, String(ln.dropFirst())))
                } else if ln.isEmpty {
                    // Treat blank line as context (common in loosely-formatted patches).
                    diff.append((.context, ""))
                } else {
                    throw PatchError(message: "unexpected hunk line at position \(i): '\(ln)' — each line in a hunk must start with ' ', '+', '-', '@@', or be blank")
                }
                i += 1
            }
            let context = diff.compactMap { $0.0 == .context ? $0.1 : nil }
            if diff.isEmpty { break }
            hunks.append(Hunk(context: context, anchor: anchor, diff: diff))
        }
        return hunks
    }

    private static func parseAddContent(lines: [String], i: inout Int) throws -> String {
        var out: [String] = []
        while i < lines.count {
            let ln = lines[i]
            let tr = ln.trimmingCharacters(in: .whitespaces)
            if tr.hasPrefix("*** Update File:")
                || tr.hasPrefix("*** Add File:")
                || tr.hasPrefix("*** Delete File:")
                || tr.hasPrefix("*** End Patch") { break }
            if ln.hasPrefix("+") {
                out.append(String(ln.dropFirst()))
            } else if ln.isEmpty {
                out.append("")
            } else {
                throw PatchError(message: "unexpected Add File line at position \(i): '\(ln)' — must start with '+'")
            }
            i += 1
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Planning (dry-run)

    private struct Plan {
        enum Kind {
            case write(path: String, newContent: Data, preImage: Data?)
            case add(path: String, content: Data)
            case delete(path: String, preImage: Data?)
            case move(fromPath: String, toPath: String, newContent: Data, preImage: Data?)
        }
        let kind: Kind
    }

    private static func planOperation(_ op: Operation) async throws -> Plan {
        switch op {
        case .add(let path, let content):
            if HarnessSecretStore.isSecretStore(path) {
                throw PatchError(message: HarnessSecretStore.wholeFileRewriteRefusal)
            }
            if FileManager.default.fileExists(atPath: path) {
                throw PatchError(message: "cannot Add File: \(path) already exists")
            }
            guard let data = content.data(using: .utf8) else {
                throw PatchError(message: "cannot encode add content for \(path)")
            }
            return Plan(kind: .add(path: path, content: data))

        case .delete(let path):
            if HarnessSecretStore.isSecretStore(path) {
                throw PatchError(message: HarnessSecretStore.deleteOrMoveRefusal)
            }
            guard FileManager.default.fileExists(atPath: path) else {
                throw PatchError(message: "cannot Delete File: \(path) does not exist")
            }
            let preImage = try? Data(contentsOf: URL(fileURLWithPath: path))
            return Plan(kind: .delete(path: path, preImage: preImage))

        case .update(let path, let hunks, let moveTo):
            guard FileManager.default.fileExists(atPath: path) else {
                throw PatchError(message: "cannot Update File: \(path) does not exist")
            }
            if HarnessSecretStore.isSecretStore(path) {
                if moveTo != nil {
                    throw PatchError(message: HarnessSecretStore.deleteOrMoveRefusal)
                }
                if let refusal = HarnessSecretStore.patchRefusal(hunks: hunks) {
                    throw PatchError(message: refusal)
                }
            } else if let moveTo, HarnessSecretStore.isSecretStore(moveTo) {
                throw PatchError(message: HarnessSecretStore.wholeFileRewriteRefusal)
            }
            try await FileTimeTracker.shared.assertFresh(path: path)
            guard let original = try? String(contentsOfFile: path, encoding: .utf8) else {
                throw PatchError(message: "file \(path) is not valid UTF-8 text")
            }
            let updated = try applyHunks(to: original, hunks: hunks, path: path)
            if HarnessSecretStore.isSecretStore(path),
               let violation = HarnessSecretStore.tokenInvariantViolation(original: original, updated: updated) {
                throw PatchError(message: violation)
            }
            guard let data = updated.data(using: .utf8) else {
                throw PatchError(message: "cannot encode updated content for \(path)")
            }
            let preImage = try? Data(contentsOf: URL(fileURLWithPath: path))
            if let moveTo {
                if FileManager.default.fileExists(atPath: moveTo) {
                    throw PatchError(message: "cannot Move to: \(moveTo) already exists")
                }
                return Plan(kind: .move(fromPath: path, toPath: moveTo, newContent: data, preImage: preImage))
            }
            return Plan(kind: .write(path: path, newContent: data, preImage: preImage))
        }
    }

    private static func applyHunks(to source: String, hunks: [Hunk], path: String) throws -> String {
        var working = source.components(separatedBy: "\n")
        for hunk in hunks {
            // Build expected "from" region: context + removed (in original order).
            var fromLines: [String] = []
            var toLines: [String] = []
            for (kind, text) in hunk.diff {
                switch kind {
                case .context:
                    fromLines.append(text); toLines.append(text)
                case .removed:
                    fromLines.append(text)
                case .added:
                    toLines.append(text)
                }
            }

            var matches = findWindowMatches(window: fromLines, in: working)
            // Fallback: strict match failed. Common cause is the model omitting
            // the leading marker space on context lines, so the parser ate one
            // space of real indent. Retry with a whitespace-tolerant match and
            // rebuild fromLines/toLines from the file's actual indentation.
            var rebuiltFromLines: [String]? = nil
            var rebuiltToLines: [String]? = nil
            if matches.isEmpty {
                let tolerant = findWindowMatchesWhitespaceTolerant(window: fromLines, in: working)
                var tolerantPick: Int? = nil
                if tolerant.count == 1 {
                    tolerantPick = tolerant[0]
                } else if tolerant.count > 1, let anchor = hunk.anchor {
                    let disambiguated = tolerant.filter { idx in
                        let lookBack = max(0, idx - 40)
                        for j in lookBack..<idx where working[j].contains(anchor) { return true }
                        return false
                    }
                    if disambiguated.count == 1 { tolerantPick = disambiguated[0] }
                }
                if let pick = tolerantPick {
                    let (fixedFrom, fixedTo) = reindentHunk(hunk: hunk, fileSlice: Array(working[pick..<(pick + fromLines.count)]))
                    rebuiltFromLines = fixedFrom
                    rebuiltToLines = fixedTo
                    matches = [pick]
                }
            }

            let effectiveFrom = rebuiltFromLines ?? fromLines
            let effectiveTo = rebuiltToLines ?? toLines

            let pickedIndex: Int
            switch matches.count {
            case 0:
                throw PatchError(message: "hunk not found in \(path)\(hunk.anchor.map { " (near @@ \($0))" } ?? "") — the context/removed lines do not match the current file")
            case 1:
                pickedIndex = matches[0]
            default:
                // Disambiguate using anchor: find an @@ anchor line within a reasonable window above each match.
                if let anchor = hunk.anchor {
                    let disambiguated = matches.filter { idx in
                        let lookBack = max(0, idx - 40)
                        for j in lookBack..<idx where working[j].contains(anchor) {
                            return true
                        }
                        return false
                    }
                    if disambiguated.count == 1 {
                        pickedIndex = disambiguated[0]
                    } else {
                        throw PatchError(message: "hunk in \(path) matches \(matches.count) locations; anchor '@@ \(anchor)' did not uniquely disambiguate (\(disambiguated.count) candidates)")
                    }
                } else {
                    throw PatchError(message: "hunk in \(path) matches \(matches.count) locations; add an '@@ <anchor>' line or more context to disambiguate")
                }
            }
            working.replaceSubrange(pickedIndex..<(pickedIndex + effectiveFrom.count), with: effectiveTo)
        }
        return working.joined(separator: "\n")
    }

    private static func findWindowMatches(window: [String], in source: [String]) -> [Int] {
        guard !window.isEmpty, window.count <= source.count else { return [] }
        var hits: [Int] = []
        for start in 0...(source.count - window.count) {
            var ok = true
            for i in 0..<window.count {
                if source[start + i] != window[i] { ok = false; break }
            }
            if ok { hits.append(start) }
        }
        return hits
    }

    /// Match `window` against `source` line-by-line, comparing each line after
    /// trimming leading/trailing whitespace. Used as a fallback when the model
    /// drops the codex marker space on context lines (or otherwise drifts on
    /// indentation). Trimmed content must still be non-empty to count — pure
    /// whitespace lines match anywhere and would explode the match set.
    private static func findWindowMatchesWhitespaceTolerant(window: [String], in source: [String]) -> [Int] {
        guard !window.isEmpty, window.count <= source.count else { return [] }
        let trimmedWindow = window.map { $0.trimmingCharacters(in: .whitespaces) }
        // Require at least one non-empty trimmed line to anchor; otherwise we'd
        // match anywhere a run of blank lines occurs.
        guard trimmedWindow.contains(where: { !$0.isEmpty }) else { return [] }
        var hits: [Int] = []
        for start in 0...(source.count - window.count) {
            var ok = true
            for i in 0..<window.count {
                if source[start + i].trimmingCharacters(in: .whitespaces) != trimmedWindow[i] {
                    ok = false; break
                }
            }
            if ok { hits.append(start) }
        }
        return hits
    }

    /// Given a hunk and the matching slice of file lines, rebuild fromLines and
    /// toLines using the file's actual indentation. Context lines are taken
    /// verbatim from the file. Added lines get a per-line indent delta inferred
    /// from the nearest patch-vs-file context-line pair (handles the common
    /// "model dropped one leading space everywhere" case).
    private static func reindentHunk(hunk: Hunk, fileSlice: [String]) -> ([String], [String]) {
        // Map each diff row to its position in fromLines (file index) — added
        // lines have no file index.
        var fileIdxForDiffRow: [Int?] = []
        var fileIdx = 0
        for (kind, _) in hunk.diff {
            switch kind {
            case .context, .removed:
                fileIdxForDiffRow.append(fileIdx)
                fileIdx += 1
            case .added:
                fileIdxForDiffRow.append(nil)
            }
        }

        // Compute indent delta from each context-line pair (file indent minus patch indent).
        // Pick the most common delta as the canonical one to apply to added lines.
        var deltaCounts: [String: Int] = [:]
        for (rowIdx, (kind, text)) in hunk.diff.enumerated() {
            guard kind == .context, let fIdx = fileIdxForDiffRow[rowIdx], fIdx < fileSlice.count else { continue }
            let fileLine = fileSlice[fIdx]
            let fileIndent = leadingWhitespace(fileLine)
            let patchIndent = leadingWhitespace(text)
            if fileIndent.hasPrefix(patchIndent) {
                let delta = String(fileIndent.dropFirst(patchIndent.count))
                deltaCounts[delta, default: 0] += 1
            }
        }
        let canonicalDelta = deltaCounts.max(by: { $0.value < $1.value })?.key ?? ""

        var rebuiltFrom: [String] = []
        var rebuiltTo: [String] = []
        for (rowIdx, (kind, text)) in hunk.diff.enumerated() {
            switch kind {
            case .context:
                if let fIdx = fileIdxForDiffRow[rowIdx], fIdx < fileSlice.count {
                    rebuiltFrom.append(fileSlice[fIdx])
                    rebuiltTo.append(fileSlice[fIdx])
                } else {
                    rebuiltFrom.append(text); rebuiltTo.append(text)
                }
            case .removed:
                if let fIdx = fileIdxForDiffRow[rowIdx], fIdx < fileSlice.count {
                    rebuiltFrom.append(fileSlice[fIdx])
                } else {
                    rebuiltFrom.append(text)
                }
            case .added:
                rebuiltTo.append(canonicalDelta + text)
            }
        }
        return (rebuiltFrom, rebuiltTo)
    }

    private static func leadingWhitespace(_ s: String) -> String {
        var end = s.startIndex
        while end < s.endIndex, s[end] == " " || s[end] == "\t" {
            end = s.index(after: end)
        }
        return String(s[s.startIndex..<end])
    }

    // MARK: - Commit

    /// Commits a single plan to disk. Returns (path, oldText, newText) when
    /// applicable so the caller can post-run LSP diagnostics and a unified
    /// diff against the freshly-saved content. Deletes return nil.
    private static func commitPlan(_ plan: Plan, applied: inout [(path: String, preImage: Data?)]) async throws -> (path: String, oldText: String, newText: String)? {
        let fm = FileManager.default
        switch plan.kind {
        case .write(let path, let newContent, let preImage):
            // Symlink and mode handling live in the write, matching
            // write_file/edit_file: the private-storage policy inside
            // Briglia's roots, resolved link + exact previous mode elsewhere.
            try PrivateStorage.fileToolEnsureParentDirectory(ofRequestedPath: path, outsideRoots: .resolveAndPreserveMode)
            try MCPAgentRouting.withLockIfRoutingFile(path) {
                try PrivateStorage.fileToolWrite(newContent, toRequestedPath: path, outsideRoots: .resolveAndPreserveMode)
            }
            applied.append((path: path, preImage: preImage))
            await FileTimeTracker.shared.recordRead(path: path)
            await FilesLedger.shared.record(path: path, origin: .edited, description: nil)
            let oldText = preImage.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return (path, oldText, String(data: newContent, encoding: .utf8) ?? "")

        case .add(let path, let content):
            try PrivateStorage.fileToolEnsureParentDirectory(ofRequestedPath: path, outsideRoots: .plain)
            try MCPAgentRouting.withLockIfRoutingFile(path) {
                try PrivateStorage.fileToolWrite(content, toRequestedPath: path, outsideRoots: .plain)
            }
            applied.append((path: path, preImage: nil))  // nil preImage = delete on rollback
            await FileTimeTracker.shared.recordRead(path: path)
            await FilesLedger.shared.record(path: path, origin: .generated, description: nil)
            return (path, "", String(data: content, encoding: .utf8) ?? "")

        case .delete(let path, let preImage):
            try MCPAgentRouting.withLockIfRoutingFile(path) { try fm.removeItem(atPath: path) }
            applied.append((path: path, preImage: preImage))
            await FileTimeTracker.shared.forget(path: path)
            await FilesLedger.shared.remove(path: path)
            return nil

        case .move(let fromPath, let toPath, let newContent, let preImage):
            try PrivateStorage.fileToolEnsureParentDirectory(ofRequestedPath: toPath, outsideRoots: .plain)
            try MCPAgentRouting.withLockIfRoutingFile(toPath) {
                try PrivateStorage.fileToolWrite(newContent, toRequestedPath: toPath, outsideRoots: .plain)
            }
            try MCPAgentRouting.withLockIfRoutingFile(fromPath) { try fm.removeItem(atPath: fromPath) }
            applied.append((path: fromPath, preImage: preImage))  // rollback restores the original
            applied.append((path: toPath, preImage: nil))          // rollback deletes the new file
            await FileTimeTracker.shared.forget(path: fromPath)
            await FileTimeTracker.shared.recordRead(path: toPath)
            await FilesLedger.shared.remove(path: fromPath)
            await FilesLedger.shared.record(path: toPath, origin: .edited, description: nil)
            let oldText = preImage.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return (toPath, oldText, String(data: newContent, encoding: .utf8) ?? "")
        }
    }

    /// Test seam (selftests only): runs right before a mid-write failure's rollback.
    nonisolated(unsafe) static var testHookBeforeRollback: (() -> Void)?

    /// Rollback is a mutation path like the commit: its writes and deletes of
    /// the MCP routing file take the routing lock too, so a restore can never
    /// land between the per-turn migration's byte check and its replacement.
    private static func rollback(applied: [(path: String, preImage: Data?)]) {
        for step in applied.reversed() {
            if let preImage = step.preImage {
                // Same write path as the commit: the policy inside Briglia's
                // roots (the restored file keeps the policy mode), the link
                // resolved elsewhere — restoring through the unresolved path
                // would replace a symlink the commit wrote through.
                try? MCPAgentRouting.withLockIfRoutingFile(step.path) {
                    try PrivateStorage.fileToolWrite(preImage, toRequestedPath: step.path, outsideRoots: .resolveOnly)
                }
            } else {
                try? MCPAgentRouting.withLockIfRoutingFile(step.path) {
                    try FileManager.default.removeItem(atPath: step.path)
                }
            }
        }
    }

    // MARK: - JSON helpers

    private static func jsonError(_ message: String) -> String {
        jsonString(["error": message])
    }

    private static func jsonString(_ dict: [String: Any]) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys, .withoutEscapingSlashes]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{\"error\": \"failed to encode response\"}"
    }
}
