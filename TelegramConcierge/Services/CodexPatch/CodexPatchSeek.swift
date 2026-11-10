import Foundation

extension CodexPatch {

    /// How permissive the match that located a pattern had to be
    /// (`seek_sequence`'s four passes, in order).
    enum FuzzLevel: Int, Comparable {
        case exact = 0, trimEnd = 1, trim = 2, punctuation = 3
        static func < (a: FuzzLevel, b: FuzzLevel) -> Bool { a.rawValue < b.rawValue }
    }

    /// `seek_sequence.rs::normalise`: trim, then map typographic punctuation
    /// and odd spaces to ASCII, scalar by scalar.
    static func normalise(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for c in RustStr.trim(s).unicodeScalars {
            switch c.value {
            case 0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2015, 0x2212: out.append("-")
            case 0x2018, 0x2019, 0x201A, 0x201B: out.append("'")
            case 0x201C, 0x201D, 0x201E, 0x201F: out.append("\"")
            case 0x00A0, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A, 0x202F, 0x205F, 0x3000:
                out.append(" ")
            default: out.append(c)
            }
        }
        return String(out)
    }

    /// The file's lines and, built lazily once per file, their transforms
    /// for the three relaxed passes (pre-release review L3: the old code
    /// re-trimmed every candidate line at every window position — O(N·M)
    /// allocations; each pass now transforms each line once and compares the
    /// stored results, which are the same strings, so the matches are the same).
    final class SeekLines {
        let lines: [String]
        private(set) lazy var trimEnd: [String] = lines.map(RustStr.trimEnd)
        private(set) lazy var trim: [String] = lines.map(RustStr.trim)
        private(set) lazy var normalised: [String] = lines.map(CodexPatch.normalise)
        init(_ lines: [String]) { self.lines = lines }
    }

    /// Cooperative cancellation for long searches (pre-release review L3):
    /// the engine sets it around preflight; a search that sees it set stops
    /// and reports no match, and the engine then returns its cancellation.
    enum SeekCancellation {
        @TaskLocal static var isCancelled: (@Sendable () -> Bool)?
    }

    /// `seek_sequence`, returning the pass that matched. `searchStart` for an
    /// EOF chunk is `max(len - pattern.len, start)` with no fallback to
    /// `start` (the code, not its doc comment).
    static func seekWithLevel(_ lines: [String], _ pattern: [String], start: Int, eof: Bool) -> (index: Int, level: FuzzLevel)? {
        seekWithLevel(SeekLines(lines), pattern, start: start, eof: eof)
    }

    static func seekWithLevel(_ file: SeekLines, _ pattern: [String], start: Int, eof: Bool) -> (index: Int, level: FuzzLevel)? {
        let lines = file.lines
        if pattern.isEmpty { return (start, .exact) }
        if pattern.count > lines.count { return nil }
        let searchStart: Int
        if eof && lines.count >= pattern.count {
            searchStart = max(lines.count - pattern.count, start)
        } else {
            searchStart = start
        }
        let upper = lines.count - pattern.count     // saturating_sub is safe: count <= lines.count
        guard searchStart <= upper else { return nil }
        let cancelled = SeekCancellation.isCancelled
        func stopped(_ i: Int) -> Bool { i & 1023 == 0 && cancelled?() == true }
        for i in searchStart...upper {
            if stopped(i) { return nil }
            if (0..<pattern.count).allSatisfy({ RustStr.eq(lines[i + $0], pattern[$0]) }) { return (i, .exact) }
        }
        let trimEndLines = file.trimEnd
        let trimEndPattern = pattern.map(RustStr.trimEnd)
        for i in searchStart...upper {
            if stopped(i) { return nil }
            if (0..<pattern.count).allSatisfy({ RustStr.eq(trimEndLines[i + $0], trimEndPattern[$0]) }) { return (i, .trimEnd) }
        }
        let trimLines = file.trim
        let trimPattern = pattern.map(RustStr.trim)
        for i in searchStart...upper {
            if stopped(i) { return nil }
            if (0..<pattern.count).allSatisfy({ RustStr.eq(trimLines[i + $0], trimPattern[$0]) }) { return (i, .trim) }
        }
        let normLines = file.normalised
        let normPattern = pattern.map(normalise)
        for i in searchStart...upper {
            if stopped(i) { return nil }
            if (0..<pattern.count).allSatisfy({ RustStr.eq(normLines[i + $0], normPattern[$0]) }) { return (i, .punctuation) }
        }
        return nil
    }

    /// `seek_sequence` as the source exposes it.
    static func seekSequence(_ lines: [String], _ pattern: [String], start: Int, eof: Bool) -> Int? {
        seekWithLevel(lines, pattern, start: start, eof: eof)?.index
    }

    /// `(start_index, old_len, new_lines)`.
    struct Replacement: Equatable {
        let start: Int
        let oldLength: Int
        let newLines: [String]
        static func == (a: Replacement, b: Replacement) -> Bool {
            a.start == b.start && a.oldLength == b.oldLength
                && a.newLines.count == b.newLines.count && zip(a.newLines, b.newLines).allSatisfy(RustStr.eq)
        }
    }

    /// `ApplyPatchError::ComputeReplacements` (Display = the message).
    struct ComputeError: Error, Equatable, CustomStringConvertible {
        enum Kind: Equatable { case context, expectedLines, overlap }
        let kind: Kind
        let message: String
        /// For hints: the lines that could not be located.
        var missedLines: [String] = []
        var description: String { message }
    }

    struct ReplacementPlan {
        var replacements: [Replacement]
        /// The most permissive pass any chunk needed.
        var fuzz: FuzzLevel
    }

    /// `compute_replacements`. `path` is the text used in error messages.
    static func computeReplacements(originalLines: [String], path: String, chunks: [Chunk]) throws -> ReplacementPlan {
        var replacements: [Replacement] = []
        var lineIndex = 0
        var fuzz = FuzzLevel.exact
        let file = SeekLines(originalLines)

        for chunk in chunks {
            if let ctx = chunk.changeContext {
                if let hit = seekWithLevel(file, [ctx], start: lineIndex, eof: false) {
                    lineIndex = hit.index + 1
                    fuzz = max(fuzz, hit.level)
                } else {
                    throw ComputeError(kind: .context, message: "Failed to find context '\(ctx)' in \(path)", missedLines: [ctx])
                }
            }

            if chunk.oldLines.isEmpty {
                replacements.append(Replacement(start: originalLines.count, oldLength: 0, newLines: chunk.newLines))
                continue
            }

            var pattern = ArraySlice(chunk.oldLines)
            var found = seekWithLevel(file, Array(pattern), start: lineIndex, eof: chunk.isEndOfFile)
            var newSlice = ArraySlice(chunk.newLines)

            if found == nil, let last = pattern.last, last.isEmpty {
                pattern = pattern.dropLast()
                if let lastNew = newSlice.last, lastNew.isEmpty { newSlice = newSlice.dropLast() }
                found = seekWithLevel(file, Array(pattern), start: lineIndex, eof: chunk.isEndOfFile)
            }

            guard let hit = found else {
                throw ComputeError(kind: .expectedLines,
                                   message: "Failed to find expected lines in \(path):\n\(chunk.oldLines.joined(separator: "\n"))",
                                   missedLines: chunk.oldLines)
            }
            fuzz = max(fuzz, hit.level)
            let startIdx = hit.index
            let patternArr = Array(pattern)
            let newArr = Array(newSlice)
            var oldStart = 0
            var newStart = 0
            for pair in chunk.contextLineIndices {
                if pair.old >= patternArr.count || pair.new >= newArr.count { break }
                if oldStart != pair.old || newStart != pair.new {
                    replacements.append(Replacement(start: startIdx + oldStart,
                                                    oldLength: pair.old - oldStart,
                                                    newLines: Array(newArr[newStart..<pair.new])))
                }
                oldStart = pair.old + 1
                newStart = pair.new + 1
            }
            if oldStart != patternArr.count || newStart != newArr.count {
                replacements.append(Replacement(start: startIdx + oldStart,
                                                oldLength: patternArr.count - oldStart,
                                                newLines: Array(newArr[newStart...])))
            }
            lineIndex = startIdx + patternArr.count
        }

        // `sort_by_key` is stable; Swift's `sort` is not guaranteed stable.
        let sorted = replacements.enumerated().sorted { a, b in
            a.element.start != b.element.start ? a.element.start < b.element.start : a.offset < b.offset
        }.map(\.element)
        return ReplacementPlan(replacements: sorted, fuzz: fuzz)
    }

    /// Briglia divergence (§6.2): Codex only `debug_assert`s non-overlap.
    static func overlapError(_ replacements: [Replacement], path: String) -> ComputeError? {
        var end = 0
        for r in replacements {
            if r.start < end { return ComputeError(kind: .overlap, message: "overlapping hunks in \(path)") }
            end = max(end, r.start + r.oldLength)
        }
        return nil
    }
}
