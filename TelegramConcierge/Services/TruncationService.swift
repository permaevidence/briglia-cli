import Foundation

/// Unified tool-output truncation with file-save fallback.
///
/// When tool output exceeds the byte or line limit, the full text is saved to
/// a temp directory and the model receives a preview (head or tail) plus a
/// hint pointing to the saved file.  The model can then use `read_file` with
/// offset/limit to inspect specific sections.
///
/// Mirrors OpenCode's `Truncate.Service` (`truncate.ts`).
enum TruncationService {

    // MARK: - Configuration

    static let maxBytes = 50 * 1024          // 50 KB
    static let maxLines = 2_000
    /// Tighter inline cap for LEGAL DOCUMENT bodies (sentenze, circolari,
    /// articles): the full text is always on disk, and legal work is usually
    /// after a specific passage — the agent greps/reads the file for the rest
    /// instead of paying ~12k tokens of context per opened document.
    /// Console/bash output and search payloads keep the default 50 KB.
    static let documentMaxBytes = 25 * 1024  // 25 KB
    /// Default: `$TMPDIR/briglia-tool-output/` (unchanged). An extra
    /// assistant: `$TMPDIR/briglia-tool-output-<name>-<h>/` with its own
    /// sweep (MULTI_ASSISTANT_PLAN §3.7; `<h>` as for its preferences suite).
    static let truncationDir = AssistantProfile.isDefault
        ? spillBase + "briglia-tool-output/"
        : spillBase + "briglia-tool-output-\(AssistantProfile.selectedName)-\(AssistantProfile.installationHash(AssistantProfile.selectedName))/"

    /// Test-only seam: `NSTemporaryDirectory()` ignores TMPDIR on macOS, so
    /// development builds accept an absolute `BRIGLIA_TEST_SPILL_ROOT` to keep
    /// selftest spill files out of the real temporary directory.
    static let testSpillRootKey = "BRIGLIA_TEST_SPILL_ROOT"
    private static var spillBase: String {
        if adaCLIVersion.hasSuffix("-dev"), let seam = ProcessInfo.processInfo.environment[testSpillRootKey],
           seam.hasPrefix("/") {
            return seam.hasSuffix("/") ? seam : seam + "/"
        }
        return NSTemporaryDirectory()
    }
    /// Pre-rename spill directory. Not deleted eagerly: existing conversations
    /// still reference files in it. Swept by the same 7-day expiry and removed
    /// once empty.
    static let legacyTruncationDir = NSTemporaryDirectory() + "ada-tool-output/"

    // MARK: - Public

    /// Result of a truncation pass.
    enum Result {
        /// Output fits within limits — returned unchanged.
        case intact(String)
        /// Output was truncated.  `preview` is the head/tail slice to send to
        /// the model; `outputPath` is where the full text was saved.
        case truncated(preview: String, outputPath: String)
    }

    /// Truncate `text` if it exceeds the configured limits.
    /// When truncated, the full text is written to a file and a preview +
    /// hint is returned.
    static func process(_ text: String, direction: Direction = .head, maxBytes: Int = TruncationService.maxBytes) -> Result {
        let data = Data(text.utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)

        if data.count <= maxBytes && lines.count <= maxLines {
            return .intact(text)
        }

        // Save the full output to a temp file.
        guard let outputPath = writeToFile(text) else {
            return .truncated(
                preview: buildPreview(text, direction: direction, outputPath: nil, maxBytes: maxBytes),
                outputPath: ""
            )
        }

        // Build the preview.
        return .truncated(
            preview: buildPreview(text, direction: direction, outputPath: outputPath, maxBytes: maxBytes),
            outputPath: outputPath
        )
    }

    /// Convenience: returns the text to embed in the tool result.
    /// If the output was not truncated, returns the original text.
    /// If truncated, returns the preview + hint.
    static func truncate(_ text: String, direction: Direction = .head, maxBytes: Int = TruncationService.maxBytes) -> (text: String, truncated: Bool, outputPath: String?) {
        switch process(text, direction: direction, maxBytes: maxBytes) {
        case .intact(let text):
            return (text, false, nil)
        case .truncated(let preview, let path):
            return (preview, true, path.isEmpty ? nil : path)
        }
    }

    /// Truncate a JSON tool payload while preserving a valid JSON response shape.
    /// Top-level collections keep their original keys and JSON types, but are
    /// reduced to a bounded slice. The full response remains available on disk.
    static func truncateJSONPayload(_ payload: [String: Any], direction: Direction = .head) -> (text: String, truncated: Bool, outputPath: String?) {
        let json = jsonString(payload)
        let processed = process(json, direction: direction)
        switch processed {
        case .intact(let text):
            return (text, false, nil)
        case .truncated(_, let path):
            var compact: [String: Any] = [:]
            var collectionKeys: [String] = []
            var originalArrayCounts: [String: Int] = [:]

            for key in payload.keys.sorted() {
                guard let value = payload[key] else { continue }
                if isScalarJSONValue(value) {
                    compact[key] = compactScalarJSONValue(value)
                }
            }

            compact["tool_output_truncated"] = true
            compact["tool_output_original_bytes"] = Data(json.utf8).count
            compact["tool_output_preview"] = shortPreview(json, direction: direction)
            if !path.isEmpty {
                compact["full_output_path"] = path
                compact["message"] = "Full output saved. Use read_file with offset and limit to inspect specific sections."
            } else {
                compact["message"] = "Output was truncated, but Briglia could not save the full output to a temporary file."
            }

            for key in payload.keys.sorted() {
                guard let value = payload[key], !isScalarJSONValue(value) else { continue }
                if let array = value as? [Any] {
                    let fitted = fitArrayValue(
                        array,
                        under: key,
                        in: compact,
                        direction: direction,
                        budgetBytes: maxBytes
                    )
                    compact[key] = fitted
                    originalArrayCounts[key] = array.count
                    if fitted.count < array.count {
                        collectionKeys.append(key)
                        compact["\(key)_tool_output_truncated"] = true
                        compact["\(key)_returned"] = fitted.count
                        compact["\(key)_total"] = array.count
                    }
                } else {
                    compact[key] = compactJSONValue(value)
                    collectionKeys.append(key)
                    compact["\(key)_tool_output_truncated"] = true
                }
            }

            if !collectionKeys.isEmpty {
                compact["tool_output_truncated_keys"] = collectionKeys
            }
            tightenJSONPayload(&compact, originalArrayCounts: originalArrayCounts, direction: direction)
            refreshTruncatedKeys(in: &compact)
            return (jsonString(compact), true, path.isEmpty ? nil : path)
        }
    }

    /// Preview for output that was streamed to a spill file as it was
    /// produced (the full text is already on disk, so unlike `process` this
    /// never re-saves). `tail` is the stream's bounded in-memory suffix;
    /// `totalBytes`/`totalLines` describe the complete stream.
    static func streamedTailPreview(tail: String, totalBytes: Int, totalLines: Int, outputPath: String?) -> String {
        // Clip the tail to the same inline budget as any other tool output.
        var lines = tail.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > maxLines { lines = Array(lines.suffix(maxLines)) }
        var preview = lines.joined(separator: "\n")
        if Data(preview.utf8).count > maxBytes {
            preview = clipUTF8(preview, maxBytes: maxBytes, fromEnd: true)
        }

        let removedBytes = max(0, totalBytes - Data(preview.utf8).count)
        let hint: String
        if let outputPath {
            hint = "Full output saved to: \(outputPath)\nUse read_file with offset/limit to view specific sections, or grep the file to locate a passage."
        } else {
            hint = "Full output could not be saved to a temporary file; only this tail was retained."
        }
        return "...\(removedBytes) bytes truncated (stream totalled \(totalBytes) bytes, \(totalLines) lines)...\n\n\(hint)\n\n\(preview)"
    }

    // MARK: - Cleanup

    /// Remove files older than 7 days. Called from context-prune maintenance,
    /// keeping directory scans out of the tool-output hot path.
    static func cleanupOldFiles() {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        sweep(directory: truncationDir, cutoff: cutoff, removeWhenEmpty: false)
        // The pre-rename pool belongs to the default install only.
        if AssistantProfile.isDefault {
            sweep(directory: legacyTruncationDir, cutoff: cutoff, removeWhenEmpty: true)
        }
    }

    private static func sweep(directory: String, cutoff: Date, removeWhenEmpty: Bool) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: directory) else { return }
        for entry in entries where entry.hasPrefix("tool_") {
            let path = directory + entry
            let attrs = try? fm.attributesOfItem(atPath: path)
            if let mtime = attrs?[.modificationDate] as? Date, mtime < cutoff {
                try? fm.removeItem(atPath: path)
            }
        }
        if removeWhenEmpty,
           let remaining = try? fm.contentsOfDirectory(atPath: directory), remaining.isEmpty {
            try? fm.removeItem(atPath: directory)
        }
    }

    // MARK: - Private

    enum Direction {
        case head
        case tail
    }

    private static func writeToFile(_ text: String) -> String? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: truncationDir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } catch {
            return nil
        }
        let filename = "tool_\(Int(Date().timeIntervalSince1970 * 1000))_\(UUID().uuidString.prefix(8)).txt"
        let path = truncationDir + filename
        do {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        return path
    }

    private static func buildPreview(_ text: String, direction: Direction, outputPath: String?, maxBytes: Int = TruncationService.maxBytes) -> String {
        let data = Data(text.utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var hitBytes = false
        let preview: String

        switch direction {
        case .head:
            var out: [String] = []
            var bytes = 0
            for line in lines {
                let lineBytes = Data(line.utf8).count + (out.isEmpty ? 0 : 1)
                if out.count >= maxLines { break }
                if bytes + lineBytes > maxBytes {
                    hitBytes = true
                    if out.isEmpty {
                        out.append(clipUTF8(String(line), maxBytes: maxBytes, fromEnd: false))
                    }
                    break
                }
                out.append(String(line))
                bytes += lineBytes
            }
            if !hitBytes { hitBytes = bytes >= maxBytes || (out.count < lines.count && out.count < maxLines) }
            preview = out.joined(separator: "\n")

        case .tail:
            var out: [String] = []
            var bytes = 0
            for line in lines.reversed() {
                let lineBytes = Data(line.utf8).count + (out.isEmpty ? 0 : 1)
                if out.count >= maxLines { break }
                if bytes + lineBytes > maxBytes {
                    hitBytes = true
                    if out.isEmpty {
                        out.insert(clipUTF8(String(line), maxBytes: maxBytes, fromEnd: true), at: 0)
                    }
                    break
                }
                out.insert(String(line), at: 0)
                bytes += lineBytes
            }
            if !hitBytes { hitBytes = bytes >= maxBytes || (out.count < lines.count && out.count < maxLines) }
            preview = out.joined(separator: "\n")
        }

        let removed: String
        if hitBytes {
            removed = "\(max(0, data.count - Data(preview.utf8).count)) bytes"
        } else {
            removed = "\(max(0, lines.count - preview.split(separator: "\n", omittingEmptySubsequences: false).count)) lines"
        }

        let hint: String
        if let outputPath {
            hint = "Full output saved to: \(outputPath)\nUse read_file with offset/limit to view specific sections, or grep the file to locate a passage (e.g. an article number or a phrase you must verify)."
        } else {
            hint = "Full output could not be saved to a temporary file."
        }

        switch direction {
        case .head:
            return "\(preview)\n\n...\(removed) truncated...\n\n\(hint)"
        case .tail:
            return "...\(removed) truncated...\n\n\(hint)\n\n\(preview)"
        }
    }

    static func clipUTF8(_ text: String, maxBytes: Int, fromEnd: Bool) -> String {
        let bytes = Array(text.utf8)
        guard bytes.count > maxBytes else { return text }
        guard maxBytes > 0 else { return "" }

        if fromEnd {
            var start = max(0, bytes.count - maxBytes)
            while start < bytes.count {
                if let clipped = String(bytes: bytes[start..<bytes.count], encoding: .utf8) {
                    return clipped
                }
                start += 1
            }
        } else {
            var end = min(maxBytes, bytes.count)
            while end > 0 {
                if let clipped = String(bytes: bytes[0..<end], encoding: .utf8) {
                    return clipped
                }
                end -= 1
            }
        }
        return ""
    }

    private static func isScalarJSONValue(_ value: Any) -> Bool {
        switch value {
        case is String, is NSNumber, is NSNull:
            return true
        default:
            return false
        }
    }

    private static func compactScalarJSONValue(_ value: Any) -> Any {
        guard let text = value as? String else { return value }
        let cap = 8 * 1024
        guard Data(text.utf8).count > cap else { return text }
        return clipUTF8(text, maxBytes: cap, fromEnd: false) + "\n...string truncated in compact tool output..."
    }

    private static func compactJSONValue(_ value: Any) -> Any {
        if isScalarJSONValue(value) {
            return compactScalarJSONValue(value)
        }
        if let array = value as? [Any] {
            return Array(array.prefix(20)).map(compactJSONValue)
        }
        if let dict = value as? [String: Any] {
            var compact: [String: Any] = [:]
            for key in dict.keys.sorted() {
                guard let child = dict[key] else { continue }
                if isScalarJSONValue(child) {
                    compact[key] = compactScalarJSONValue(child)
                }
            }
            return compact
        }
        return String(describing: value)
    }

    private static func fitArrayValue(
        _ array: [Any],
        under key: String,
        in basePayload: [String: Any],
        direction: Direction,
        budgetBytes: Int
    ) -> [Any] {
        var fitted: [Any] = []
        let source: [Any]
        switch direction {
        case .head:
            source = array
        case .tail:
            source = Array(array.reversed())
        }

        for rawElement in source {
            let element = compactJSONValue(rawElement)
            let candidateArray: [Any]
            switch direction {
            case .head:
                candidateArray = fitted + [element]
            case .tail:
                candidateArray = [element] + fitted
            }

            var candidatePayload = basePayload
            candidatePayload[key] = candidateArray
            if jsonByteCount(candidatePayload) > budgetBytes {
                break
            }
            fitted = candidateArray
        }

        return fitted
    }

    private static func tightenJSONPayload(
        _ payload: inout [String: Any],
        originalArrayCounts: [String: Int],
        direction: Direction
    ) {
        while jsonByteCount(payload) > maxBytes {
            guard let key = largestArrayKey(in: payload) else { break }
            guard var array = payload[key] as? [Any], !array.isEmpty else { break }
            switch direction {
            case .head:
                array.removeLast()
            case .tail:
                array.removeFirst()
            }
            payload[key] = array
            payload["\(key)_returned"] = array.count
            if let original = originalArrayCounts[key], array.count < original {
                payload["\(key)_tool_output_truncated"] = true
            }
        }

        if jsonByteCount(payload) > maxBytes {
            payload["tool_output_preview"] = shortPreview(String(payload["tool_output_preview"] as? String ?? ""), direction: direction, maxPreviewBytes: 1_024)
        }
        if jsonByteCount(payload) > maxBytes {
            payload.removeValue(forKey: "tool_output_preview")
        }
    }

    private static func refreshTruncatedKeys(in payload: inout [String: Any]) {
        let suffix = "_tool_output_truncated"
        let keys = payload.keys.compactMap { key -> String? in
            guard key.hasSuffix(suffix), payload[key] as? Bool == true else { return nil }
            return String(key.dropLast(suffix.count))
        }.sorted()

        if keys.isEmpty {
            payload.removeValue(forKey: "tool_output_truncated_keys")
        } else {
            payload["tool_output_truncated_keys"] = keys
        }
    }

    private static func largestArrayKey(in payload: [String: Any]) -> String? {
        payload
            .compactMap { key, value -> (String, Int)? in
                guard let array = value as? [Any], !array.isEmpty else { return nil }
                return (key, jsonByteCount(array))
            }
            .max { $0.1 < $1.1 }?
            .0
    }

    private static func shortPreview(_ text: String, direction: Direction, maxPreviewBytes: Int = 4 * 1024) -> String {
        switch direction {
        case .head:
            return clipUTF8(text, maxBytes: maxPreviewBytes, fromEnd: false)
        case .tail:
            return clipUTF8(text, maxBytes: maxPreviewBytes, fromEnd: true)
        }
    }

    private static func jsonByteCount(_ value: Any) -> Int {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return Int.max
        }
        return data.count
    }

    private static func jsonString(_ dict: [String: Any]) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys, .withoutEscapingSlashes]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{\"error\":\"failed to encode response\"}"
    }
}
