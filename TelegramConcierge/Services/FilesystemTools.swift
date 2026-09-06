import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// Core filesystem tool implementations: read_file, write_file, edit_file.
/// Apply_patch lives in its own file (`ApplyPatch.swift`).
///
/// All methods take an absolute path (never relative, never ~-expanded by tilde alone —
/// the caller should pass the already-expanded path). These return plain result shapes;
/// the ToolExecutor wraps them into ToolResultMessage when dispatching.
actor FilesystemTools {
    static let shared = FilesystemTools()

    // Caps — mirror Claude Code's Read tool.
    static let maxLines = 2000
    static let maxBytes = 256 * 1024         // 256 KB cap for text output (matches Claude Code)
    static let maxLineLength = 2000          // truncate lines longer than this
    static let maxTokens = 25_000            // token cap for text reads (matches Claude Code)

    // Image caps — mirror Claude Code's auto-downscale behavior.
    static let imageMaxLongSide = 1568        // Anthropic's internal resize cap
    static let imageMaxTokens = 5_000         // token budget per image read
    static let imageDownscaleQuality: CGFloat = 0.80  // JPEG quality for resized images

    struct ReadResult {
        let content: String
        let attachments: [FileAttachment]
    }

    struct OpResult {
        let content: String
    }

    private init() {}

    // MARK: - read_file

    // PDF containment (matches Claude Code's Read tool).
    static let pdfPagesRequiredThreshold = 20
    static let pdfMaxPagesPerCall = 20

    /// Read a text file (paginated) OR load an image/PDF as a FileAttachment for
    /// multimodal injection. Always snapshots FileTime on success.
    /// `pages` (for PDFs only): range string like "1-5", "3", or "10-20". Required when the
    /// PDF has more than 20 pages; capped at 20 pages per call.
    func readFile(path rawPath: String, offset: Int? = nil, limit: Int? = nil, pages: String? = nil) async -> ReadResult {
        let path = Self.normalizePath(rawPath)

        guard Self.isAbsolute(path) else {
            return ReadResult(content: jsonError("path must be absolute (start with '/' or '~')"), attachments: [])
        }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
            var message = "file not found: \(path)"
            let suggestions = DiscoveryTools.didYouMean(for: path)
            if !suggestions.isEmpty {
                message += ". Did you mean: \(suggestions.joined(separator: ", "))"
            }
            return ReadResult(content: jsonError(message), attachments: [])
        }
        if isDir.boolValue {
            return ReadResult(content: jsonError("path is a directory, not a file. Use list_dir instead: \(path)"), attachments: [])
        }

        // Resolve symlinks once. Stat-based checks (type guard, size cap, freshness ledger)
        // must observe the target the read actually touches — statting the link inode would
        // let a symlink bypass the 256 KB cap and void the stale-write protection.
        let resolvedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path

        // Reject non-regular files up front: opening a FIFO or device node for reading can
        // block forever, and this actor serializes all filesystem tools behind it.
        // (Directories were handled above; symlinks are resolved, so .typeRegular is the
        // only type a readable file can have here.)
        if let type = (try? fm.attributesOfItem(atPath: resolvedPath))?[.type] as? FileAttributeType,
           type != .typeRegular {
            return ReadResult(content: jsonError("cannot read \(path): not a regular file (\(type.rawValue)). FIFOs, sockets, and device files cannot be read with this tool."), attachments: [])
        }

        let mime = Self.mimeType(forPath: path)

        // Images → multimodal attachment, auto-downscaled if needed.
        if mime.hasPrefix("image/") && mime != "image/svg+xml" {
            do {
                var data = try Data(contentsOf: URL(fileURLWithPath: path))
                let filename = (path as NSString).lastPathComponent
                let originalBytes = data.count
                var finalMime = mime
                var wasResized = false

                if let downscaled = Self.downscaledForModelBudget(data) {
                    data = downscaled.data
                    finalMime = downscaled.mimeType
                    wasResized = true
                }

                await FileTimeTracker.shared.recordRead(path: path)
                let attachment = FileAttachment(data: data, mimeType: finalMime, filename: filename, sourcePath: path)
                var summary: [String: Any] = [
                    "success": true,
                    "path": path,
                    "mime_type": finalMime,
                    "size_bytes": data.count,
                    "message": "Image attached. It will be visible to you on the next turn as a user-role multimodal message."
                ]
                if wasResized {
                    summary["resized"] = true
                    summary["original_size_bytes"] = originalBytes
                    summary["message"] = "Image was auto-downscaled to fit within \(Self.imageMaxLongSide)px (token budget). Attached as JPEG."
                }
                return ReadResult(content: jsonString(summary), attachments: [attachment])
            } catch {
                return ReadResult(content: jsonError("failed to read \(path): \(error.localizedDescription)"), attachments: [])
            }
        }

        // PDFs → enforce page-range caps, slice if needed.
        if mime == "application/pdf" {
            return await Self.readPDF(path: path, pages: pages)
        }

        // Text path. Reject other binaries.
        if Self.looksBinary(mime: mime, path: path) {
            return ReadResult(content: jsonError("cannot read binary file \(path) (mime=\(mime)). Use bash tools if you need to inspect it."), attachments: [])
        }

        // E88-style hard ceiling: whole-file reads are capped at 256 KB (matches Claude Code's
        // Read tool). If the file exceeds that AND the caller didn't request a slice, refuse
        // with the same wording Claude Code emits — the agent must paginate via offset/limit
        // or search for specific content instead.
        if offset == nil && limit == nil,
           let attrs = try? fm.attributesOfItem(atPath: resolvedPath),
           let fileSize = attrs[.size] as? Int,
           fileSize > Self.maxBytes {
            let sizeKB = Double(fileSize) / 1024.0
            let msg = String(
                format: "File content (%.1fKB) exceeds maximum allowed size (256KB). Use offset and limit parameters to read specific portions of the file, or search for specific content instead of reading the whole file.",
                sizeKB
            )
            return ReadResult(content: jsonError(msg), attachments: [])
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let decodedText: String
            var decodedAsLatin1 = false
            if let utf8 = String(data: data, encoding: .utf8) {
                decodedText = utf8
            } else if let latin1 = String(data: data, encoding: .isoLatin1) {
                // Latin-1 decoding never fails, so this is the terminal fallback: the file is
                // some non-UTF-8 encoding and may render as mojibake. Disclose it in the payload.
                decodedText = latin1
                decodedAsLatin1 = true
            } else {
                return ReadResult(content: jsonError("file \(path) is not valid UTF-8 or Latin-1 text"), attachments: [])
            }
            // Briglia's own secret store is shown with the Telegram bot token masked
            // (HarnessSecretStore); every other value is returned verbatim.
            let isSubscription = URL(fileURLWithPath: resolvedPath).standardizedFileURL == SubscriptionAuthStore().file.resolvingSymlinksInPath().standardizedFileURL
            let text = isSubscription ? "[Subscription OAuth credentials omitted; use briglia subscription status]" : HarnessSecretStore.isSecretStore(resolvedPath)
                ? HarnessSecretStore.maskedForRead(decodedText)
                : decodedText

            let allLines = text.components(separatedBy: "\n")
            let startLine = max((offset ?? 1) - 1, 0)           // offset is 1-indexed
            if startLine >= allLines.count {
                await FileTimeTracker.shared.recordRead(path: path)
                return ReadResult(
                    content: jsonString([
                        "success": true,
                        "path": path,
                        "total_lines": allLines.count,
                        "returned_lines": 0,
                        "offset": offset ?? 1,
                        "truncated": false,
                        "content": "",
                        "message": "offset \(offset ?? 1) exceeds file length (\(allLines.count) lines)"
                    ]),
                    attachments: []
                )
            }
            // Non-positive limits (e.g. `limit: -1` as a "no limit" idiom) fall back to the
            // default — a negative value would otherwise build an invalid Range below and trap.
            let requestedLimit = limit ?? Self.maxLines
            let effectiveLimit = requestedLimit > 0 ? requestedLimit : Self.maxLines
            let endLine = min(startLine + effectiveLimit, allLines.count)
            var slice = Array(allLines[startLine..<endLine])
            var truncatedLongLines = 0
            for i in slice.indices {
                if slice[i].count > Self.maxLineLength {
                    slice[i] = String(slice[i].prefix(Self.maxLineLength)) + "… [line truncated at \(Self.maxLineLength) chars]"
                    truncatedLongLines += 1
                }
            }
            // Prepend 1-indexed line numbers so the agent can reference exact lines
            // when editing. Format: right-aligned to the width of the last line number, then "→".
            // Example: "  42→let x = 1".
            let lastLineNumber = startLine + slice.count
            let numWidth = String(lastLineNumber).count
            for i in slice.indices {
                let n = startLine + i + 1
                let padded = String(repeating: " ", count: max(0, numWidth - String(n).count)) + String(n)
                slice[i] = "\(padded)→\(slice[i])"
            }
            var joined = slice.joined(separator: "\n")
            var bytesTruncated = false
            // 1-indexed line number of the last line actually included. Defaults to endLine,
            // but the byte cap may cut the body short — recompute so counts/offset stay accurate.
            var lastShownLine = endLine
            if Data(joined.utf8).count > Self.maxBytes {
                // Trim to a valid UTF-8 boundary (clipUTF8 never falls back to the full text),
                // then drop any partial trailing line so the reported line count is accurate.
                joined = TruncationService.clipUTF8(joined, maxBytes: Self.maxBytes, fromEnd: false)
                if let lastNewline = joined.lastIndex(of: "\n") {
                    joined = String(joined[..<lastNewline])
                }
                let shownLines = joined.isEmpty ? 0 : joined.components(separatedBy: "\n").count
                lastShownLine = startLine + shownLines
                joined += "\n… [output capped at \(Self.maxBytes) bytes]"
                bytesTruncated = true
            }

            // Token cap (matches Claude Code): reject if content exceeds 25K tokens.
            // Only enforced for whole-file reads (no explicit limit) to match CC behavior.
            let estimatedTokens = joined.utf8.count / 4
            if limit == nil && estimatedTokens > Self.maxTokens {
                let msg = "File content (~\(estimatedTokens) tokens) exceeds maximum allowed tokens (\(Self.maxTokens)). Use offset and limit parameters to read specific portions of the file, or use grep to search for specific content instead of reading the whole file."
                return ReadResult(content: jsonError(msg), attachments: [])
            }

            // Seed the read-before-write ledger only after every rejection path has passed —
            // a rejected read must not unlock write_file/edit_file over content the model
            // never saw. (The 256 KB pre-check above already rejects before seeding; this
            // keeps the token-cap path consistent with it.)
            await FileTimeTracker.shared.recordRead(path: path)

            let truncated = lastShownLine < allLines.count || bytesTruncated
            var result: [String: Any] = [
                "success": true,
                "path": path,
                "total_lines": allLines.count,
                "returned_lines": lastShownLine - startLine,
                "offset": startLine + 1,
                "truncated": truncated,
                "content": joined
            ]
            if truncated {
                result["message"] = "File truncated. Returned lines \(startLine + 1)..\(lastShownLine) of \(allLines.count). Call read_file again with offset=\(lastShownLine + 1) for more."
            }
            if truncatedLongLines > 0 {
                result["long_lines_truncated"] = truncatedLongLines
            }
            if decodedAsLatin1 {
                result["encoding"] = "latin-1"
                result["encoding_warning"] = "file is not valid UTF-8 and was decoded as ISO Latin-1 — content from other encodings (Windows-1252, Shift-JIS, UTF-16 …) may appear garbled"
            }
            return ReadResult(content: jsonString(result), attachments: [])
        } catch {
            return ReadResult(content: jsonError("failed to read \(path): \(error.localizedDescription)"), attachments: [])
        }
    }

    // MARK: - write_file

    /// Create or overwrite a file. If the file exists, the agent must have read it this session;
    /// FileTime is asserted before write. Overwrites preserve the pre-image's line endings
    /// (CRLF), UTF-8 BOM, and POSIX mode, and write through symlinks instead of replacing them.
    func writeFile(path rawPath: String, content: String, description: String? = nil) async -> OpResult {
        let path = Self.normalizePath(rawPath)
        guard Self.isAbsolute(path) else {
            return OpResult(content: jsonError("path must be absolute: \(rawPath)"))
        }
        if HarnessSecretStore.isSecretStore(path) {
            return OpResult(content: jsonError(HarnessSecretStore.wholeFileRewriteRefusal))
        }
        if let suspicion = Self.escapedNewlineSuspicion(content: content, path: path) {
            return OpResult(content: jsonError(suspicion))
        }

        let fm = FileManager.default
        let fileExists = fm.fileExists(atPath: path)
        // Capture the pre-image before overwriting: content for the unified diff,
        // line ending + BOM so a rewrite doesn't silently change the file's on-disk
        // representation. The POSIX mode and a symlink at the path are handled by
        // the write itself (`PrivateStorage.fileToolWrite`): inside Briglia's
        // roots the private-storage policy applies (owner bits kept, group/other
        // stripped, link resolved and its target classified); elsewhere the
        // file is the user's and keeps its exact previous mode.
        let previousFile: TextFileSnapshot?
        if fileExists {
            do {
                try await FileTimeTracker.shared.assertFresh(path: path)
            } catch {
                return OpResult(content: jsonError(error.localizedDescription))
            }
            previousFile = try? Self.readTextFileSnapshot(path: path)
        } else {
            previousFile = nil
        }

        var finalText = content
        var convertedToCRLF = false
        var preservedBOM = false
        if let previousFile {
            if previousFile.lineEnding == .crlf && !content.contains("\r\n") {
                finalText = Self.restoreLineEndings(Self.normalizeLineEndings(content), as: .crlf)
                convertedToCRLF = true
            }
            preservedBOM = previousFile.hasUTF8BOM && !content.hasPrefix("\u{FEFF}")
        }

        do {
            try PrivateStorage.fileToolEnsureParentDirectory(ofRequestedPath: path, outsideRoots: .resolveAndPreserveMode)
            var finalData = Data()
            if preservedBOM {
                finalData.append(contentsOf: [0xEF, 0xBB, 0xBF])
            }
            finalData.append(Data(finalText.utf8))
            try MCPAgentRouting.withLockIfRoutingFile(path) {
                try PrivateStorage.fileToolWrite(finalData, toRequestedPath: path, outsideRoots: .resolveAndPreserveMode)
            }
            // Refresh FileTime snapshot so subsequent edits still pass the staleness check.
            await FileTimeTracker.shared.recordRead(path: path)
            let origin: FilesLedger.Origin = fileExists ? .edited : .generated
            await FilesLedger.shared.record(path: path, origin: origin, description: description)
            var result: [String: Any] = [
                "success": true,
                "path": path,
                "bytes_written": finalData.count,
                "operation": fileExists ? "overwrote" : "created"
            ]
            if convertedToCRLF {
                result["line_endings"] = "content converted to CRLF to match the existing file"
            }
            if preservedBOM {
                result["bom"] = "existing UTF-8 BOM preserved"
            }
            if let diff = DiffUtil.unifiedDiff(old: previousFile?.content ?? "", new: finalText, path: path) {
                result["diff"] = diff
            }
            await LSPDiagnosticsReporter.attach(to: &result, path: path, updatedText: finalText)
            return OpResult(content: jsonString(result))
        } catch {
            return OpResult(content: jsonError("failed to write \(path): \(error.localizedDescription)"))
        }
    }

    /// Heuristic guard against a known weak-model failure mode: emitting an entire
    /// multi-line file as a single line with literal backslash-n sequences instead of
    /// real newlines. Only fires when the content has NO real newlines at all —
    /// legitimate code freely mixes "\n" string literals with real line breaks.
    /// Exemptions: valid JSON (minified JSON packs \n escapes into one line) and
    /// *.min.* assets (minified bundles do the same).
    static func escapedNewlineSuspicion(content: String, path: String) -> String? {
        guard !content.contains("\n"), content.count >= 200 else { return nil }
        let literalCount = content.components(separatedBy: "\\n").count - 1
        guard literalCount >= 5 else { return nil }
        let filename = (path as NSString).lastPathComponent.lowercased()
        if filename.contains(".min.") { return nil }
        if let data = content.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return nil
        }
        return "content contains \(literalCount) literal \\n sequences but not a single real newline — the newlines were almost certainly escaped as text during generation. Nothing was written. Resend the content with actual newline characters. If this single-line content is genuinely intentional, write the file via bash instead."
    }

    // MARK: - edit_file

    /// Single-edit convenience wrapper — delegates to the batch method.
    func editFile(path rawPath: String, oldString: String, newString: String, replaceAll: Bool = false) async -> OpResult {
        return await editFile(path: rawPath, edits: [EditPair(oldString: oldString, newString: newString)], replaceAll: replaceAll)
    }

    /// A single old/new replacement pair.
    struct EditPair {
        let oldString: String
        let newString: String
    }

    /// Batch edit: apply one or more find/replace pairs atomically.
    /// All edits are matched against the ORIGINAL file content (not incrementally).
    /// If any edit fails validation, the file is untouched.
    /// Falls back through 3 match strategies per edit: literal → line-trimmed → whitespace-normalized.
    func editFile(path rawPath: String, edits: [EditPair], replaceAll: Bool = false) async -> OpResult {
        let path = Self.normalizePath(rawPath)
        guard Self.isAbsolute(path) else {
            return OpResult(content: jsonError("path must be absolute: \(rawPath)"))
        }
        guard !edits.isEmpty else {
            return OpResult(content: jsonError("edit_file requires at least one edit"))
        }
        for (i, edit) in edits.enumerated() {
            if edit.oldString.isEmpty {
                let label = edits.count > 1 ? "edits[\(i)]: " : ""
                return OpResult(content: jsonError("\(label)old_string must not be empty"))
            }
            if edit.oldString == edit.newString {
                let label = edits.count > 1 ? "edits[\(i)]: " : ""
                return OpResult(content: jsonError("\(label)old_string and new_string are identical — nothing to do"))
            }
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return OpResult(content: jsonError("file not found: \(path). Use write_file to create it."))
        }
        if HarnessSecretStore.isSecretStore(path) {
            for edit in edits {
                if let refusal = HarnessSecretStore.editRefusal(oldText: edit.oldString, newText: edit.newString) {
                    return OpResult(content: jsonError(refusal))
                }
            }
        }
        do {
            try await FileTimeTracker.shared.assertFresh(path: path)
        } catch {
            return OpResult(content: jsonError(error.localizedDescription))
        }

        let originalFile: TextFileSnapshot
        do {
            originalFile = try Self.readTextFileSnapshot(path: path)
        } catch {
            return OpResult(content: jsonError("file \(path) is not valid UTF-8 text"))
        }
        let original = originalFile.normalizedContent

        // --- Phase 1: Match all edits against the ORIGINAL content ---
        struct MatchedEdit {
            let index: Int
            let range: Range<String.Index>
            let newString: String
            let strategy: String
        }

        var matchedEdits: [MatchedEdit] = []
        var usedNonLiteral = false

        for (i, edit) in edits.enumerated() {
            let label = edits.count > 1 ? "edits[\(i)]: " : ""
            let normalizedOld = Self.normalizeLineEndings(edit.oldString)
            let normalizedNew = Self.normalizeLineEndings(edit.newString)

            switch EditStrategies.findMatches(source: original, oldString: normalizedOld, replaceAll: replaceAll) {
            case .noMatch:
                let hint = EditStrategies.escapeMismatchHint(source: original, oldString: normalizedOld) ?? ""
                return OpResult(content: jsonError("\(label)old_string not found in \(path). It must match exactly including whitespace and indentation.\(hint)"))
            case .multipleMatches(let count):
                return OpResult(content: jsonError("\(label)old_string occurs \(count) times in \(path). Provide more surrounding context to make it unique, or pass replace_all=true."))
            case .success(let matches, let strategy):
                if strategy != "literal" { usedNonLiteral = true }

                for match in matches {
                    matchedEdits.append(MatchedEdit(
                        index: i,
                        range: match.range,
                        newString: normalizedNew,
                        strategy: strategy
                    ))
                }
            }
        }

        // --- Phase 2: Check for overlaps ---
        let sorted = matchedEdits.sorted { $0.range.lowerBound < $1.range.lowerBound }
        for j in 1..<sorted.count {
            let prev = sorted[j - 1]
            let curr = sorted[j]
            if prev.range.upperBound > curr.range.lowerBound {
                return OpResult(content: jsonError("edits[\(prev.index)] and edits[\(curr.index)] overlap. Merge them into one edit or target disjoint regions."))
            }
        }

        // --- Phase 3: Apply all edits (last-to-first to keep positions stable) ---
        var updated = original
        let sortedReversed = matchedEdits.sorted { $0.range.lowerBound > $1.range.lowerBound }
        for m in sortedReversed {
            updated.replaceSubrange(m.range, with: m.newString)
        }

        if updated == original {
            return OpResult(content: jsonError("No changes made. The replacement produced identical content."))
        }
        // Harness secret store: the text-level refusals above catch the obvious
        // cases; the invariant that matters is checked on the RESULT — the
        // token entry must be byte-identical after the edit (an edit can hit
        // a substring of the token or of the field name without containing
        // either in full).
        if HarnessSecretStore.isSecretStore(path),
           let violation = HarnessSecretStore.tokenInvariantViolation(original: original, updated: updated) {
            return OpResult(content: jsonError(violation))
        }

        // --- Phase 4: Write and report ---
        do {
            let finalText = Self.restoreLineEndings(updated, as: originalFile.lineEnding)
            var finalData = Data()
            if originalFile.hasUTF8BOM {
                finalData.append(contentsOf: [0xEF, 0xBB, 0xBF])
            }
            finalData.append(Data(finalText.utf8))
            // Symlink and mode handling live in the write itself, matching
            // write_file: policy inside Briglia's roots, exact previous mode
            // and resolved link elsewhere.
            try MCPAgentRouting.withLockIfRoutingFile(path) {
                try PrivateStorage.fileToolWrite(finalData, toRequestedPath: path, outsideRoots: .resolveAndPreserveMode)
            }
            await FileTimeTracker.shared.recordRead(path: path)
            await FilesLedger.shared.record(path: path, origin: .edited, description: nil)
            var result: [String: Any] = [
                "success": true,
                "path": path,
                "edits_applied": matchedEdits.count,
                "bytes_written": finalData.count
            ]
            if let diff = DiffUtil.unifiedDiff(old: originalFile.content, new: finalText, path: path) {
                result["diff"] = diff
            }
            if usedNonLiteral {
                let strategies = Array(Set(matchedEdits.map(\.strategy).filter { $0 != "literal" })).sorted()
                result["match_strategy_warning"] = "One or more edits applied using fuzzy matching (\(strategies.joined(separator: ", "))). Inspect the diff carefully."
                result["match_strategies"] = strategies
            }
            await LSPDiagnosticsReporter.attach(to: &result, path: path, updatedText: finalText)
            return OpResult(content: jsonString(result))
        } catch {
            return OpResult(content: jsonError("failed to write \(path): \(error.localizedDescription)"))
        }
    }

    // MARK: - Helpers

    static func normalizePath(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("~") {
            return (trimmed as NSString).expandingTildeInPath
        }
        return trimmed
    }

    struct TextFileSnapshot {
        let content: String
        let normalizedContent: String
        let lineEnding: LineEnding
        let hasUTF8BOM: Bool
    }

    enum LineEnding {
        case lf
        case crlf
    }

    static func readTextFileSnapshot(path: String) throws -> TextFileSnapshot {
        var data = try Data(contentsOf: URL(fileURLWithPath: path))
        let hasBOM = data.starts(with: [0xEF, 0xBB, 0xBF])
        if hasBOM {
            data.removeFirst(3)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return TextFileSnapshot(
            content: text,
            normalizedContent: normalizeLineEndings(text),
            lineEnding: detectLineEnding(text),
            hasUTF8BOM: hasBOM
        )
    }

    static func detectLineEnding(_ text: String) -> LineEnding {
        if let crlf = text.range(of: "\r\n"),
           let lf = text.range(of: "\n") {
            return crlf.lowerBound <= lf.lowerBound ? .crlf : .lf
        }
        return .lf
    }

    static func normalizeLineEndings(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    static func restoreLineEndings(_ text: String, as lineEnding: LineEnding) -> String {
        switch lineEnding {
        case .lf:
            return text
        case .crlf:
            return text.replacingOccurrences(of: "\n", with: "\r\n")
        }
    }

    static func isAbsolute(_ path: String) -> Bool {
        path.hasPrefix("/")
    }

    static func mimeType(forPath path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        if ext.isEmpty { return "application/octet-stream" }
        #if canImport(UniformTypeIdentifiers)
        if let uti = UTType(filenameExtension: ext), let mime = uti.preferredMIMEType {
            return mime
        }
        #endif
        // Fallback table — the only lookup path on Linux, so it carries the
        // media types UTType normally resolves on macOS.
        switch ext {
        case "txt", "md", "log": return "text/plain"
        case "swift": return "text/x-swift"
        case "py": return "text/x-python"
        case "js", "mjs", "cjs": return "text/javascript"
        case "ts", "tsx": return "text/typescript"
        case "json": return "application/json"
        case "yaml", "yml": return "application/yaml"
        case "html", "htm": return "text/html"
        case "css": return "text/css"
        case "xml": return "application/xml"
        case "csv": return "text/csv"
        case "rtf": return "application/rtf"
        case "pdf": return "application/pdf"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "heif": return "image/heif"
        case "bmp": return "image/bmp"
        case "tif", "tiff": return "image/tiff"
        case "svg": return "image/svg+xml"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "wav": return "audio/wav"
        case "ogg", "oga": return "audio/ogg"
        case "opus": return "audio/opus"
        case "flac": return "audio/flac"
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        case "avi": return "video/x-msvideo"
        case "mkv": return "video/x-matroska"
        case "webm": return "video/webm"
        case "zip": return "application/zip"
        case "gz": return "application/gzip"
        case "doc": return "application/msword"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xls": return "application/vnd.ms-excel"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "ppt": return "application/vnd.ms-powerpoint"
        case "pptx": return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "epub": return "application/epub+zip"
        default: return "application/octet-stream"
        }
    }

    static func isMultimodalMime(_ mime: String) -> Bool {
        mime.hasPrefix("image/") && mime != "image/svg+xml"
            || mime == "application/pdf"
    }

    // MARK: - PDF page-range handling (parity with Claude Code Read)

    /// Load a PDF, optionally slice to a page range, and return a FileAttachment.
    /// - PDFs with <= `pdfPagesRequiredThreshold` pages: returned whole when `pages` is omitted.
    /// - PDFs with more pages: `pages` is REQUIRED. Missing → error telling the agent the page count
    ///   and requiring a range.
    /// - `pages` always capped at `pdfMaxPagesPerCall` pages per call.
    static func readPDF(path: String, pages: String?) async -> ReadResult {
        func err(_ msg: String) -> ReadResult {
            ReadResult(content: "{\"error\": \(jsonLiteral(msg))}", attachments: [])
        }
        guard let doc = AdaPDF(url: URL(fileURLWithPath: path)) else {
            return err("failed to open PDF: \(path)")
        }
        let totalPages = doc.pageCount
        guard totalPages > 0 else {
            return err("PDF \(path) has zero pages.")
        }

        // Determine which pages to include.
        let requestedRange: ClosedRange<Int>
        if let p = pages?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
            guard let parsed = parsePageRange(p, totalPages: totalPages) else {
                return err("invalid pages value '\(p)'. Use formats like '3', '1-5', or '10-20'. PDF has \(totalPages) pages.")
            }
            requestedRange = parsed
        } else if totalPages > pdfPagesRequiredThreshold {
            return err("PDF \(path) has \(totalPages) pages — too large to read in one call. Specify a page range via the 'pages' parameter (e.g. pages=\"1-5\" or pages=\"10-20\"). Max \(pdfMaxPagesPerCall) pages per call.")
        } else {
            requestedRange = 1...totalPages
        }

        let spanned = requestedRange.upperBound - requestedRange.lowerBound + 1
        guard spanned <= pdfMaxPagesPerCall else {
            return err("page range '\(pages ?? "")' spans \(spanned) pages. Max \(pdfMaxPagesPerCall) pages per call.")
        }

        // Build a sliced PDF containing only the requested pages.
        let slicedData: Data
        let slicedPageCount: Int
        if requestedRange.lowerBound == 1 && requestedRange.upperBound == totalPages {
            // Whole document — return the original bytes.
            do {
                slicedData = try Data(contentsOf: URL(fileURLWithPath: path))
                slicedPageCount = totalPages
            } catch {
                return err("failed to load PDF bytes: \(error.localizedDescription)")
            }
        } else {
            guard let data = doc.sliceData(pages: requestedRange) else {
                return err("failed to serialize sliced PDF for range \(requestedRange.lowerBound)-\(requestedRange.upperBound).")
            }
            slicedData = data
            slicedPageCount = requestedRange.count
        }

        await FileTimeTracker.shared.recordRead(path: path)
        let filename = (path as NSString).lastPathComponent
        let pageRange = "\(requestedRange.lowerBound)-\(requestedRange.upperBound)"
        let attachment = FileAttachment(data: slicedData, mimeType: "application/pdf", filename: filename, sourcePath: path, pageRange: pageRange)
        let summary: [String: Any] = [
            "success": true,
            "path": path,
            "mime_type": "application/pdf",
            "total_pages": totalPages,
            "pages_returned": slicedPageCount,
            "page_range": pageRange,
            "size_bytes": slicedData.count,
            "message": "PDF pages \(requestedRange.lowerBound)–\(requestedRange.upperBound) of \(totalPages) attached. They will be visible to you on the next turn as a user-role multimodal message."
        ]
        return ReadResult(content: jsonStringStatic(summary), attachments: [attachment])
    }

    /// Parse "3", "1-5", "10-20" → ClosedRange<Int> clamped to [1, totalPages].
    /// Returns nil on malformed input or ranges outside [1, totalPages].
    static func parsePageRange(_ raw: String, totalPages: Int) -> ClosedRange<Int>? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if let single = Int(s) {
            guard single >= 1, single <= totalPages else { return nil }
            return single...single
        }
        let parts = s.split(separator: "-", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let lo = Int(parts[0]), let hi = Int(parts[1]) else { return nil }
        guard lo >= 1, hi >= lo, lo <= totalPages else { return nil }
        let clampedHi = min(hi, totalPages)
        return lo...clampedHi
    }

    private static func jsonLiteral(_ s: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes]),
           let str = String(data: data, encoding: .utf8) {
            // Strip the surrounding brackets to get just the quoted+escaped string.
            let trimmed = str.dropFirst().dropLast()
            return String(trimmed)
        }
        return "\"\(s.replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private static func jsonStringStatic(_ dict: [String: Any]) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys, .withoutEscapingSlashes]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{\"error\": \"failed to encode response\"}"
    }

    /// Heuristic: if mime is known text-ish, treat as text. Otherwise check for null bytes.
    static func looksBinary(mime: String, path: String) -> Bool {
        if mime.hasPrefix("text/") { return false }
        if mime == "application/json"
            || mime == "application/yaml"
            || mime == "application/xml"
            || mime == "application/javascript"
            || mime == "image/svg+xml" { return false }
        // Sample first 4KB for null bytes.
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return true }
        defer { try? handle.close() }
        let sample = (try? handle.read(upToCount: 4096)) ?? Data()
        return sample.contains(0)
    }

    private func jsonError(_ message: String) -> String {
        jsonString(["error": message])
    }

    private func jsonString(_ dict: [String: Any]) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys, .withoutEscapingSlashes]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{\"error\": \"failed to encode response\"}"
    }

    // MARK: - Image downscaling

    /// Downscale an image to the model ingestion budget (imageMaxLongSide /
    /// imageMaxTokens), re-encoding as JPEG. Returns nil when the image is
    /// already within budget or can't be decoded (caller keeps the original).
    static func downscaledForModelBudget(_ data: Data) -> (data: Data, mimeType: String)? {
        guard let dims = PlatformImage.dimensions(data: data) else { return nil }
        let (w, h) = dims

        let estimatedTokens = (w * h) / 750
        let longSide = max(w, h)
        guard estimatedTokens > imageMaxTokens || longSide > imageMaxLongSide else { return nil }

        let scale = Double(imageMaxLongSide) / Double(longSide)
        let targetSize = CGSize(width: Int(Double(w) * scale), height: Int(Double(h) * scale))
        guard let resized = PlatformImage.resizeToJPEG(
            data: data, targetSize: targetSize, quality: imageDownscaleQuality
        ) else { return nil }
        return (resized, "image/jpeg")
    }

    /// Bring a rasterized PDF page under the same ingestion budget image files
    /// get. The rasterizer emits lossless PNGs (1–3 MB per page at 2× scale);
    /// an over-budget page is downscaled to imageMaxLongSide, and an in-budget
    /// page is re-encoded as JPEG at the same dimensions — either way the wire
    /// cost typically drops ~10–20×. The output is NEVER larger than the
    /// input: sparse pages (line art, mostly-white scans) can PNG-compress
    /// below their JPEG, and then the original is kept even when its
    /// dimensions exceed the budget. Also fails soft to the original when
    /// dimensions can't be probed or the re-encode fails (ImageMagick missing
    /// on Linux).
    static func recompressedRenderedPage(_ pageData: Data) -> (data: Data, mimeType: String) {
        let original = (pageData, sniffedImageMime(pageData))
        if let downscaled = downscaledForModelBudget(pageData) {
            return downscaled.data.count < pageData.count ? downscaled : original
        }
        guard let dims = PlatformImage.dimensions(data: pageData),
              let jpeg = PlatformImage.resizeToJPEG(
                  data: pageData,
                  targetSize: CGSize(width: dims.width, height: dims.height),
                  quality: imageDownscaleQuality
              ),
              jpeg.count < pageData.count else {
            return original
        }
        return (jpeg, "image/jpeg")
    }

    /// Magic-byte MIME sniff for the two formats this pipeline produces.
    private static func sniffedImageMime(_ data: Data) -> String {
        data.prefix(2) == Data([0xFF, 0xD8]) ? "image/jpeg" : "image/png"
    }
}

// MARK: - Edit match strategies

enum EditStrategies {
    enum MatchOutcome {
        case noMatch
        case multipleMatches(count: Int)
        case success(matches: [MatchRange], strategy: String)
    }

    struct MatchRange {
        let range: Range<String.Index>
    }

    private struct SourceLine {
        let text: String
        let range: Range<String.Index>
    }

    /// Find exact source ranges for oldString without building a replacement string.
    static func findMatches(source: String, oldString: String, replaceAll: Bool) -> MatchOutcome {
        let literalRanges = rangesOf(needle: oldString, inHaystack: source)
        if !literalRanges.isEmpty {
            if literalRanges.count > 1 && !replaceAll {
                return .multipleMatches(count: literalRanges.count)
            }
            return .success(matches: literalRanges.map { MatchRange(range: $0) }, strategy: "literal")
        }

        let sourceLines = linesWithRanges(in: source)
        if let ranges = findLineTrimmedRanges(sourceLines: sourceLines, oldString: oldString) {
            if ranges.count > 1 && !replaceAll {
                return .multipleMatches(count: ranges.count)
            }
            return .success(matches: ranges.map { MatchRange(range: $0) }, strategy: "line-trimmed")
        }

        if let ranges = findWhitespaceNormalizedRanges(sourceLines: sourceLines, oldString: oldString) {
            if ranges.count > 1 && !replaceAll {
                return .multipleMatches(count: ranges.count)
            }
            return .success(matches: ranges.map { MatchRange(range: $0) }, strategy: "whitespace-normalized")
        }

        return .noMatch
    }

    /// Diagnostic only — never used to apply an edit. When all strategies fail,
    /// detects whether old_string and the file differ purely in escape-sequence
    /// representation (literal backslash-n bytes vs a real newline), a common
    /// failure mode of weaker models. Applying such a match would write the
    /// model's (equally mis-escaped) new_string into the file, so instead we
    /// fail loud with a hint telling the model to re-read the exact bytes.
    static func escapeMismatchHint(source: String, oldString: String) -> String? {
        guard oldString.contains("\\") || source.contains("\\") else { return nil }

        let unescapedOld = unescapeCommonSequences(oldString)
        if unescapedOld != oldString, source.contains(unescapedOld) {
            return " Hint: your old_string contains literal escape sequences (backslash + n/t/r/slash/quote) where the file has the actual characters (real newlines/tabs/slashes/quotes). Re-read the file and resend old_string with the file's exact bytes."
        }

        if source.contains("\\") {
            let unescapedSource = unescapeCommonSequences(source)
            if unescapedSource != source, unescapedSource.contains(unescapedOld) {
                return " Hint: the file contains literal escape sequences (backslash + n/t/r/quote) where your old_string has the actual characters. Re-read the file and reproduce its escape sequences exactly as written."
            }
        }

        return nil
    }

    private static func unescapeCommonSequences(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        var out = ""
        out.reserveCapacity(text.count)
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            let next = text.index(after: i)
            if ch == "\\", next < text.endIndex {
                let replacement: Character?
                switch text[next] {
                case "n": replacement = "\n"
                case "t": replacement = "\t"
                case "r": replacement = "\r"
                case "\"": replacement = "\""
                case "'": replacement = "'"
                case "`": replacement = "`"
                case "/": replacement = "/"
                case "\\": replacement = "\\"
                default: replacement = nil
                }
                if let replacement {
                    out.append(replacement)
                    i = text.index(after: next)
                    continue
                }
            }
            out.append(ch)
            i = text.index(after: i)
        }
        return out
    }

    private static func linesWithRanges(in source: String) -> [SourceLine] {
        var lines: [SourceLine] = []
        var lineStart = source.startIndex
        var index = source.startIndex

        while index < source.endIndex {
            if source[index] == "\n" {
                lines.append(SourceLine(text: String(source[lineStart..<index]), range: lineStart..<index))
                index = source.index(after: index)
                lineStart = index
            } else {
                index = source.index(after: index)
            }
        }

        lines.append(SourceLine(text: String(source[lineStart..<source.endIndex]), range: lineStart..<source.endIndex))
        return lines
    }

    private static func findLineTrimmedRanges(sourceLines: [SourceLine], oldString: String) -> [Range<String.Index>]? {
        let oldLines = oldString
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t")) }
        guard !oldLines.isEmpty, oldLines.count <= sourceLines.count else { return nil }

        var ranges: [Range<String.Index>] = []
        for start in 0...(sourceLines.count - oldLines.count) {
            var hit = true
            for i in 0..<oldLines.count {
                let srcLine = sourceLines[start + i].text.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
                if srcLine != oldLines[i] { hit = false; break }
            }
            if hit {
                ranges.append(sourceLines[start].range.lowerBound..<sourceLines[start + oldLines.count - 1].range.upperBound)
            }
        }
        return ranges.isEmpty ? nil : ranges
    }

    private static func findWhitespaceNormalizedRanges(sourceLines: [SourceLine], oldString: String) -> [Range<String.Index>]? {
        func normalize(_ s: String) -> String {
            let collapsed = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            return collapsed.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t")) }
                .joined(separator: "\n")
        }

        let normalizedOld = normalize(oldString)
        let oldLineCount = oldString.components(separatedBy: "\n").count
        guard oldLineCount > 0, oldLineCount <= sourceLines.count else { return nil }

        var ranges: [Range<String.Index>] = []
        for start in 0...(sourceLines.count - oldLineCount) {
            let window = sourceLines[start..<(start + oldLineCount)].map(\.text).joined(separator: "\n")
            if normalize(window) == normalizedOld {
                ranges.append(sourceLines[start].range.lowerBound..<sourceLines[start + oldLineCount - 1].range.upperBound)
            }
        }
        return ranges.isEmpty ? nil : ranges
    }

    private static func rangesOf(needle: String, inHaystack haystack: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        guard !needle.isEmpty else { return ranges }
        var searchStart = haystack.startIndex
        while let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            ranges.append(range)
            searchStart = range.upperBound
        }
        return ranges
    }
}
