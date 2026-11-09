import Foundation

/// Rust `str` semantics the Codex port depends on (GPT_APPLY_PATCH_PLAN
/// §6.1–6.3). Swift `String` compares and slices by grapheme cluster with
/// canonical equivalence (`"é" == "e\u{301}"`, CRLF is one `Character`);
/// Rust compares bytes and iterates Unicode scalars. Every comparison,
/// prefix test and trim in the engine goes through these helpers so the port
/// never broadens Rust's exact behaviour.
enum RustStr {
    /// Rust `char::is_whitespace` is the Unicode `White_Space` property.
    @inline(__always)
    static func isWhitespace(_ s: Unicode.Scalar) -> Bool { s.properties.isWhitespace }

    /// `str::trim`.
    static func trim(_ s: String) -> String {
        let scalars = s.unicodeScalars
        guard let first = scalars.firstIndex(where: { !isWhitespace($0) }) else { return "" }
        let last = scalars.lastIndex(where: { !isWhitespace($0) })!
        return String(String.UnicodeScalarView(scalars[first...last]))
    }

    /// `str::trim_end`.
    static func trimEnd(_ s: String) -> String {
        let scalars = s.unicodeScalars
        guard let last = scalars.lastIndex(where: { !isWhitespace($0) }) else { return "" }
        return String(String.UnicodeScalarView(scalars[...last]))
    }

    /// `str::lines` (Rust ≥ 1.77): split after every `\n`; drop the `\n`
    /// and then one `\r` before it; a final segment without `\n` is kept
    /// as is (a lone trailing `\r` stays); no empty final line.
    static func lines(_ s: String) -> [String] {
        var out: [String] = []
        var current = String.UnicodeScalarView()
        var any = false
        for scalar in s.unicodeScalars {
            any = true
            if scalar == "\n" {
                if let last = current.last, last == "\r" { current.removeLast() }
                out.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        if any, !current.isEmpty { out.append(String(current)) }
        return out
    }

    /// Byte equality (Rust `==` on `str`).
    @inline(__always)
    static func eq(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

    /// `str::strip_prefix` for an ASCII or arbitrary prefix, byte-wise.
    static func stripPrefix(_ s: String, _ prefix: String) -> String? {
        let su = s.utf8, pu = prefix.utf8
        guard su.count >= pu.count, su.starts(with: pu) else { return nil }
        return String(decoding: su.dropFirst(pu.count), as: UTF8.self)
    }

    static func hasPrefix(_ s: String, _ prefix: String) -> Bool { s.utf8.starts(with: prefix.utf8) }

    static func hasSuffix(_ s: String, _ suffix: String) -> Bool {
        let su = s.utf8, xu = suffix.utf8
        return su.count >= xu.count && su.suffix(xu.count).elementsEqual(xu)
    }

    static func join(_ parts: [String], _ sep: String) -> String { parts.joined(separator: sep) }
}

/// Port of `codex-rs/apply-patch` at the pinned commit
/// `4e4767ffa763ec0d0a19e04cf8ff0163a987297b` (Apache-2.0; see
/// `scripts/fixtures/codex-apply-patch/pinned/LICENSE` and
/// THIRD_PARTY_NOTICES.md). Where the plan paraphrases and the pinned source
/// disagrees, the source wins, except for the intentional divergences of
/// plan §6.9 (implemented in the planner and transaction, never here).
enum CodexPatch {
    static let beginPatchMarker = "*** Begin Patch"
    static let endPatchMarker = "*** End Patch"
    static let addFileMarker = "*** Add File: "
    static let deleteFileMarker = "*** Delete File: "
    static let updateFileMarker = "*** Update File: "
    static let moveToMarker = "*** Move to: "
    static let eofMarker = "*** End of File"
    static let changeContextMarker = "@@ "
    static let emptyChangeContextMarker = "@@"
    static let environmentIDMarker = "*** Environment ID:"

    // MARK: - Types (parser.rs)

    enum ParseError: Error, Equatable, CustomStringConvertible {
        case invalidPatch(String)
        case invalidHunk(message: String, lineNumber: Int)

        /// `#[error("invalid patch: {0}")]` / `#[error("invalid hunk at line {line_number}, {message}")]`
        var description: String {
            switch self {
            case .invalidPatch(let m): return "invalid patch: \(m)"
            case .invalidHunk(let m, let n): return "invalid hunk at line \(n), \(m)"
            }
        }

        static func == (a: ParseError, b: ParseError) -> Bool {
            switch (a, b) {
            case (.invalidPatch(let x), .invalidPatch(let y)): return RustStr.eq(x, y)
            case (.invalidHunk(let m1, let n1), .invalidHunk(let m2, let n2)): return n1 == n2 && RustStr.eq(m1, m2)
            default: return false
            }
        }
    }

    struct ContextPair: Equatable { let old: Int; let new: Int }

    struct Chunk: Equatable, CustomStringConvertible {
        var changeContext: String?
        var oldLines: [String] = []
        var newLines: [String] = []
        var contextLineIndices: [ContextPair] = []
        var isEndOfFile = false

        init(changeContext: String? = nil, oldLines: [String] = [], newLines: [String] = [],
             contextLineIndices: [ContextPair] = [], isEndOfFile: Bool = false) {
            self.changeContext = changeContext
            self.oldLines = oldLines
            self.newLines = newLines
            self.contextLineIndices = contextLineIndices
            self.isEndOfFile = isEndOfFile
        }

        /// `push_context_line`.
        mutating func pushContextLine(_ line: String) {
            contextLineIndices.append(ContextPair(old: oldLines.count, new: newLines.count))
            oldLines.append(line)
            newLines.append(line)
        }

        var isEmpty: Bool { oldLines.isEmpty && newLines.isEmpty }

        static func == (a: Chunk, b: Chunk) -> Bool {
            func optEq(_ x: String?, _ y: String?) -> Bool {
                switch (x, y) { case (nil, nil): return true; case let (x?, y?): return RustStr.eq(x, y); default: return false }
            }
            return optEq(a.changeContext, b.changeContext)
                && a.oldLines.count == b.oldLines.count && zip(a.oldLines, b.oldLines).allSatisfy(RustStr.eq)
                && a.newLines.count == b.newLines.count && zip(a.newLines, b.newLines).allSatisfy(RustStr.eq)
                && a.contextLineIndices == b.contextLineIndices && a.isEndOfFile == b.isEndOfFile
        }

        var description: String {
            "Chunk(ctx: \(changeContext.map { "\"\($0)\"" } ?? "nil"), old: \(oldLines), new: \(newLines), ctxIdx: \(contextLineIndices.map { "(\($0.old),\($0.new))" }), eof: \(isEndOfFile))"
        }
    }

    struct Hunk: Equatable, CustomStringConvertible {
        enum Kind: Equatable { case add, delete, update }
        var kind: Kind
        var path: String
        var contents: String = ""          // add
        var movePath: String? = nil        // update
        var chunks: [Chunk] = []           // update

        static func add(_ path: String, _ contents: String) -> Hunk { Hunk(kind: .add, path: path, contents: contents) }
        static func delete(_ path: String) -> Hunk { Hunk(kind: .delete, path: path) }
        static func update(_ path: String, move: String? = nil, _ chunks: [Chunk]) -> Hunk {
            Hunk(kind: .update, path: path, movePath: move, chunks: chunks)
        }

        /// `Hunk::path()`: the move destination for renames.
        var affectedPath: String { kind == .update ? (movePath ?? path) : path }

        static func == (a: Hunk, b: Hunk) -> Bool {
            guard a.kind == b.kind, RustStr.eq(a.path, b.path) else { return false }
            switch a.kind {
            case .add: return RustStr.eq(a.contents, b.contents)
            case .delete: return true
            case .update:
                let mv: Bool
                switch (a.movePath, b.movePath) {
                case (nil, nil): mv = true
                case let (x?, y?): mv = RustStr.eq(x, y)
                default: mv = false
                }
                return mv && a.chunks == b.chunks
            }
        }

        var description: String {
            switch kind {
            case .add: return "Add(\(path), \(contents.debugDescription))"
            case .delete: return "Delete(\(path))"
            case .update: return "Update(\(path), move: \(movePath ?? "nil"), \(chunks))"
            }
        }
    }

    struct Args: Equatable {
        var hunks: [Hunk]
        var patch: String
        var environmentID: String?
        static func == (a: Args, b: Args) -> Bool {
            a.hunks == b.hunks && RustStr.eq(a.patch, b.patch) && a.environmentID == b.environmentID
        }
    }

    // MARK: - parse_patch (lenient mode)

    enum ParseMode { case strict, lenient }

    /// `parse_patch`: the pinned source uses lenient mode for every model.
    static func parsePatch(_ patch: String) throws -> Args {
        try parsePatchText(patch, mode: .lenient)
    }

    static func parsePatchText(_ patch: String, mode: ParseMode) throws -> Args {
        let lines = RustStr.lines(RustStr.trim(patch))
        let patchLines: ArraySlice<String>
        switch mode {
        case .strict: patchLines = try checkPatchBoundariesStrict(lines[...])
        case .lenient: patchLines = try checkPatchBoundariesLenient(lines[...])
        }
        let joined = patchLines.joined(separator: "\n")
        var parser = StreamingParser()
        _ = try parser.pushDelta(joined)
        let hunks = try parser.finish()
        return Args(hunks: hunks, patch: joined, environmentID: parser.environmentID)
    }

    static func checkPatchBoundariesStrict(_ lines: ArraySlice<String>) throws -> ArraySlice<String> {
        try checkStartAndEndLinesStrict(first: lines.first, last: lines.last)
        return lines
    }

    static func checkPatchBoundariesLenient(_ original: ArraySlice<String>) throws -> ArraySlice<String> {
        let originalError: Error
        do { return try checkPatchBoundariesStrict(original) } catch { originalError = error }
        guard original.count >= 2, let first = original.first, let last = original.last else { throw originalError }
        if (RustStr.eq(first, "<<EOF") || RustStr.eq(first, "<<'EOF'") || RustStr.eq(first, "<<\"EOF\""))
            && RustStr.hasSuffix(last, "EOF")
            && original.count >= 4 {
            let inner = original[(original.startIndex + 1)..<(original.endIndex - 1)]
            return try checkPatchBoundariesStrict(inner)
        }
        throw originalError
    }

    static func checkStartAndEndLinesStrict(first: String?, last: String?) throws {
        let f = first.map(RustStr.trim)
        let l = last.map(RustStr.trim)
        if let f, let l, RustStr.eq(f, beginPatchMarker), RustStr.eq(l, endPatchMarker) { return }
        if let f, !RustStr.eq(f, beginPatchMarker) {
            throw ParseError.invalidPatch("The first line of the patch must be '*** Begin Patch'")
        }
        throw ParseError.invalidPatch("The last line of the patch must be '*** End Patch'")
    }

    // MARK: - StreamingPatchParser (streaming_parser.rs)

    struct StreamingParser {
        enum Mode: Equatable {
            case notStarted, startedPatch, addFile, deleteFile
            case updateFile(hunkLineNumber: Int)
            case endedPatch
        }

        private var lineBuffer = String.UnicodeScalarView()
        private(set) var mode: Mode = .notStarted
        private(set) var hunks: [Hunk] = []
        private(set) var environmentID: String?
        private var lineNumber = 0

        init() {}

        private func ensureUpdateHunkIsNotEmpty(_ line: String) throws {
            guard let last = hunks.last, last.kind == .update else { return }
            if last.chunks.isEmpty, case .updateFile(let hunkLineNumber) = mode {
                throw ParseError.invalidHunk(message: "Update file hunk for path '\(last.path)' is empty", lineNumber: hunkLineNumber)
            }
            if let chunk = last.chunks.last, chunk.isEmpty {
                if RustStr.eq(line, endPatchMarker) {
                    throw ParseError.invalidHunk(message: "Update hunk does not contain any lines", lineNumber: lineNumber)
                }
                throw ParseError.invalidHunk(message: "Unexpected line found in update hunk: '\(line)'. Every line should start with ' ' (context line), '+' (added line), or '-' (removed line)", lineNumber: lineNumber)
            }
        }

        private mutating func handleHunkHeadersAndEndPatch(_ trimmed: String) throws -> Bool {
            if mode == .startedPatch, let env = RustStr.stripPrefix(trimmed, environmentIDMarker) {
                if environmentID != nil {
                    throw ParseError.invalidPatch("apply_patch environment_id cannot be specified more than once")
                }
                let id = RustStr.trim(env)
                if id.isEmpty { throw ParseError.invalidPatch("apply_patch environment_id cannot be empty") }
                environmentID = id
                return true
            }
            if RustStr.eq(trimmed, endPatchMarker) {
                try ensureUpdateHunkIsNotEmpty(trimmed)
                mode = .endedPatch
                return true
            }
            if let path = RustStr.stripPrefix(trimmed, addFileMarker) {
                try ensureUpdateHunkIsNotEmpty(trimmed)
                hunks.append(.add(path, ""))
                mode = .addFile
                return true
            }
            if let path = RustStr.stripPrefix(trimmed, deleteFileMarker) {
                try ensureUpdateHunkIsNotEmpty(trimmed)
                hunks.append(.delete(path))
                mode = .deleteFile
                return true
            }
            if let path = RustStr.stripPrefix(trimmed, updateFileMarker) {
                try ensureUpdateHunkIsNotEmpty(trimmed)
                hunks.append(.update(path, []))
                mode = .updateFile(hunkLineNumber: lineNumber)
                return true
            }
            return false
        }

        /// `push_delta`: buffers by Unicode scalar (Rust `chars()`), processes
        /// every complete line with one trailing `\r` removed.
        @discardableResult
        mutating func pushDelta(_ delta: String) throws -> [Hunk] {
            for scalar in delta.unicodeScalars {
                if scalar == "\n" {
                    var line = lineBuffer
                    lineBuffer = String.UnicodeScalarView()
                    if let last = line.last, last == "\r" { line.removeLast() }
                    lineNumber += 1
                    try processLine(String(line))
                } else {
                    lineBuffer.append(scalar)
                }
            }
            return hunks
        }

        mutating func finish() throws -> [Hunk] {
            if !lineBuffer.isEmpty {
                let line = String(lineBuffer)
                lineBuffer = String.UnicodeScalarView()
                lineNumber += 1
                if RustStr.eq(RustStr.trim(line), endPatchMarker) {
                    try ensureUpdateHunkIsNotEmpty(RustStr.trim(line))
                    mode = .endedPatch
                } else {
                    try processLine(line)
                }
            }
            guard mode == .endedPatch else {
                throw ParseError.invalidPatch("The last line of the patch must be '*** End Patch'")
            }
            return hunks
        }

        private static func invalidHeader(_ trimmed: String, _ n: Int) -> ParseError {
            .invalidHunk(message: "'\(trimmed)' is not a valid hunk header. Valid hunk headers: '*** Add File: {path}', '*** Delete File: {path}', '*** Update File: {path}'", lineNumber: n)
        }

        private static func unexpectedUpdateLine(_ line: String, _ n: Int) -> ParseError {
            .invalidHunk(message: "Unexpected line found in update hunk: '\(line)'. Every line should start with ' ' (context line), '+' (added line), or '-' (removed line)", lineNumber: n)
        }

        private mutating func processLine(_ line: String) throws {
            let trimmed = RustStr.trim(line)
            switch mode {
            case .notStarted:
                if RustStr.eq(trimmed, beginPatchMarker) { mode = .startedPatch; return }
                throw ParseError.invalidPatch("The first line of the patch must be '*** Begin Patch'")
            case .startedPatch:
                if try handleHunkHeadersAndEndPatch(trimmed) { return }
                throw Self.invalidHeader(trimmed, lineNumber)
            case .addFile:
                if try handleHunkHeadersAndEndPatch(trimmed) { return }
                if let toAdd = RustStr.stripPrefix(line, "+"), let idx = hunks.indices.last, hunks[idx].kind == .add {
                    hunks[idx].contents += toAdd
                    hunks[idx].contents += "\n"
                    return
                }
                throw Self.invalidHeader(trimmed, lineNumber)
            case .deleteFile:
                if try handleHunkHeadersAndEndPatch(trimmed) { return }
                throw Self.invalidHeader(trimmed, lineNumber)
            case .updateFile(let hunkLineNumber):
                let updateLine = RustStr.trimEnd(line)
                if try handleHunkHeadersAndEndPatch(updateLine) { return }
                if let idx = hunks.indices.last, hunks[idx].kind == .update {
                    var hunk = hunks[idx]
                    defer { hunks[idx] = hunk }
                    if let lastChunk = hunk.chunks.last, lastChunk.isEndOfFile {
                        if updateLine.isEmpty { return }
                        if !RustStr.eq(updateLine, emptyChangeContextMarker) && !RustStr.hasPrefix(updateLine, changeContextMarker) {
                            throw ParseError.invalidHunk(message: "Expected update hunk to start with a @@ context marker, got: '\(line)'", lineNumber: lineNumber)
                        }
                    }
                    if hunk.chunks.isEmpty, hunk.movePath == nil, let moveTo = RustStr.stripPrefix(updateLine, moveToMarker) {
                        hunk.movePath = moveTo
                        mode = .updateFile(hunkLineNumber: hunkLineNumber)
                        return
                    }
                    if (RustStr.eq(updateLine, emptyChangeContextMarker) || RustStr.hasPrefix(updateLine, changeContextMarker)),
                       let lastChunk = hunk.chunks.last, lastChunk.isEmpty {
                        throw Self.unexpectedUpdateLine(line, lineNumber)
                    }
                    if RustStr.eq(updateLine, emptyChangeContextMarker) {
                        hunk.chunks.append(Chunk())
                        mode = .updateFile(hunkLineNumber: hunkLineNumber)
                        return
                    }
                    if let ctx = RustStr.stripPrefix(updateLine, changeContextMarker) {
                        hunk.chunks.append(Chunk(changeContext: ctx))
                        mode = .updateFile(hunkLineNumber: hunkLineNumber)
                        return
                    }
                    if RustStr.eq(updateLine, eofMarker) {
                        if let lastChunk = hunk.chunks.last, lastChunk.isEmpty {
                            throw ParseError.invalidHunk(message: "Update hunk does not contain any lines", lineNumber: lineNumber)
                        }
                        if !hunk.chunks.isEmpty { hunk.chunks[hunk.chunks.count - 1].isEndOfFile = true }
                        mode = .updateFile(hunkLineNumber: hunkLineNumber)
                        return
                    }
                    if line.isEmpty {
                        if hunk.chunks.isEmpty { hunk.chunks.append(Chunk()) }
                        hunk.chunks[hunk.chunks.count - 1].pushContextLine("")
                        mode = .updateFile(hunkLineNumber: hunkLineNumber)
                        return
                    }
                    if let ctx = RustStr.stripPrefix(line, " ") {
                        if hunk.chunks.isEmpty { hunk.chunks.append(Chunk()) }
                        hunk.chunks[hunk.chunks.count - 1].pushContextLine(ctx)
                        mode = .updateFile(hunkLineNumber: hunkLineNumber)
                        return
                    }
                    if let added = RustStr.stripPrefix(line, "+") {
                        if hunk.chunks.isEmpty { hunk.chunks.append(Chunk()) }
                        hunk.chunks[hunk.chunks.count - 1].newLines.append(added)
                        mode = .updateFile(hunkLineNumber: hunkLineNumber)
                        return
                    }
                    if let removed = RustStr.stripPrefix(line, "-") {
                        if hunk.chunks.isEmpty { hunk.chunks.append(Chunk()) }
                        hunk.chunks[hunk.chunks.count - 1].oldLines.append(removed)
                        mode = .updateFile(hunkLineNumber: hunkLineNumber)
                        return
                    }
                    if let lastChunk = hunk.chunks.last, !lastChunk.isEmpty {
                        throw ParseError.invalidHunk(message: "Expected update hunk to start with a @@ context marker, got: '\(line)'", lineNumber: lineNumber)
                    }
                }
                throw Self.unexpectedUpdateLine(line, lineNumber)
            case .endedPatch:
                if trimmed.isEmpty { return }
                throw ParseError.invalidPatch("The last line of the patch must be '*** End Patch'")
            }
        }
    }
}
