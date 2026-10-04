import Foundation

/// The user profile (`structured_user_context`) as numbered facts, and the
/// deterministic application of a maintenance reply's `drop` / `edit` / `add`
/// operations (USER_CONTEXT_EDIT_OPS_PLAN §4).
///
/// Pure: no I/O, no clock. The profile stays plain text; parsing keeps every
/// line's raw bytes apart from its editable content, so lines no operation
/// touches render byte-for-byte as they were (including a trailing `\r`).
///
/// One line = one fact. Headings (first non-space character `#`) and blank
/// lines are structure: never numbered, edited or dropped by the model.
struct UserProfileDocument {
    enum Kind: Equatable { case heading, blank, fact }

    struct Line: Equatable {
        /// The line's bytes without its `\n` delimiter (a CRLF line keeps its `\r`).
        var raw: String
        var kind: Kind
        /// Leading whitespace plus an optional list marker (`- `, `* `, `• `, `1. `, `1) `).
        var prefix: String
        /// What the model sees and edits: the rest of the line without a trailing `\r`.
        var content: String
        /// Raw text (without `\r`) of the nearest heading above, or "".
        var section: String
        /// Heading level (number of leading `#`), 0 for other kinds.
        var level: Int
    }

    private(set) var lines: [Line]
    /// Whether the text ended with `\n` (the last line is followed by a delimiter).
    private(set) var endsWithNewline: Bool

    init(_ text: String) {
        var bytes = Array(text.utf8)
        endsWithNewline = bytes.last == 0x0A
        if endsWithNewline { bytes.removeLast() }
        var parsed: [Line] = []
        var section = ""
        if !(bytes.isEmpty && !endsWithNewline) {
            // Split on the 0x0A byte: never on Character boundaries, where
            // Swift treats "\r\n" as one grapheme.
            for segment in bytes.split(separator: 0x0A, omittingEmptySubsequences: false) {
                let raw = String(decoding: segment, as: UTF8.self)
                var line = Self.classify(raw)
                if line.kind == .heading {
                    section = line.content
                    line.section = section
                } else {
                    line.section = section
                }
                parsed.append(line)
            }
        }
        lines = parsed
    }

    private init(lines: [Line], endsWithNewline: Bool) {
        self.lines = lines
        self.endsWithNewline = endsWithNewline
    }

    static func classify(_ raw: String) -> Line {
        let body = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return Line(raw: raw, kind: .blank, prefix: "", content: "", section: "", level: 0)
        }
        if trimmed.hasPrefix("#") {
            let level = trimmed.prefix(while: { $0 == "#" }).count
            return Line(raw: raw, kind: .heading, prefix: "", content: body, section: "", level: level)
        }
        let scalars = Array(body.unicodeScalars)
        var index = 0
        while index < scalars.count, scalars[index] == " " || scalars[index] == "\t" { index += 1 }
        var markerEnd = index
        if index + 1 < scalars.count, ["-", "*", "•"].contains(scalars[index]), scalars[index + 1] == " " {
            markerEnd = index + 2
        } else {
            var digits = index
            while digits < scalars.count, ("0"..."9").contains(scalars[digits]) { digits += 1 }
            if digits > index, digits + 1 < scalars.count, scalars[digits] == "." || scalars[digits] == ")",
               scalars[digits + 1] == " " {
                markerEnd = digits + 2
            }
        }
        var prefixView = String.UnicodeScalarView()
        prefixView.append(contentsOf: scalars[0..<markerEnd])
        var contentView = String.UnicodeScalarView()
        contentView.append(contentsOf: scalars[markerEnd...])
        return Line(raw: raw, kind: .fact, prefix: String(prefixView), content: String(contentView), section: "", level: 0)
    }

    func render() -> String {
        lines.map(\.raw).joined(separator: "\n") + (endsWithNewline && !lines.isEmpty ? "\n" : "")
    }

    /// Indices into `lines` of the facts, in document order: fact `id` is
    /// `factLineIndices[id - 1]`.
    var factLineIndices: [Int] { lines.indices.filter { lines[$0].kind == .fact } }
    var factCount: Int { factLineIndices.count }
    var characterCount: Int { render().count }

    /// The numbered profile shown to the model: headings verbatim, each fact
    /// as `[id] (length) content`, blank lines dropped.
    func numberedListing() -> String {
        var out: [String] = []
        var id = 0
        for line in lines {
            switch line.kind {
            case .heading: out.append(line.content)
            case .blank: continue
            case .fact:
                id += 1
                out.append("[\(id)] (\(line.content.count) chars) \(line.content)")
            }
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Operations

    struct Edit: Equatable { let id: Int; let text: String }
    struct Add: Equatable { let text: String; let after: Int? }

    /// A decoded reply. Elements that failed validation are recorded as
    /// `ignored` (one invalid op never voids the others).
    struct Operations: Equatable {
        var drop: [Int] = []
        var edit: [Edit] = []
        var add: [Add] = []
        var ignored: [String] = []
        var isEmpty: Bool { drop.isEmpty && edit.isEmpty && add.isEmpty }
    }

    enum ReplyError: Error, Equatable, CustomStringConvertible {
        case empty, noJSONObject, malformed(String), duplicateKey(String), notAnObject
        var description: String {
            switch self {
            case .empty: return "empty reply"
            case .noJSONObject: return "reply contains no JSON object"
            case .malformed(let why): return "malformed JSON (\(why))"
            case .duplicateKey(let key): return "duplicate JSON key \"\(key)\""
            case .notAnObject: return "reply is not a JSON object"
            }
        }
    }

    /// Reply handling (§7.7): `NO_CHANGES` or `{}` = no change; otherwise the
    /// first `{` to its string-aware matching `}` (fences/prose stripped),
    /// strict token-level parse with duplicate-key detection.
    static func parseReply(_ reply: String, factCount: Int) throws -> Operations {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw ReplyError.empty }
        if trimmed == "NO_CHANGES" { return Operations() }
        guard let objectText = extractFirstObject(trimmed) else { throw ReplyError.noJSONObject }
        let value: StrictJSON.Value
        do { value = try StrictJSON.parse(objectText) }
        catch let error as StrictJSON.ParseError {
            if case .duplicateKey(let key) = error { throw ReplyError.duplicateKey(key) }
            throw ReplyError.malformed(error.description)
        }
        guard case .object(let fields) = value else { throw ReplyError.notAnObject }
        var ops = Operations()
        func validID(_ value: StrictJSON.Value) -> Int? {
            if case .int(let id) = value, (1...max(factCount, 1)).contains(id), factCount > 0 { return id }
            return nil
        }
        for (key, field) in fields {
            switch key {
            case "drop":
                guard case .array(let items) = field else { ops.ignored.append("drop: not an array"); continue }
                for item in items {
                    if let id = validID(item) { ops.drop.append(id) }
                    else { ops.ignored.append("drop \(item.brief): not a fact id in 1…\(factCount)") }
                }
            case "edit":
                guard case .array(let items) = field else { ops.ignored.append("edit: not an array"); continue }
                for item in items {
                    guard case .object(let pairs) = item else { ops.ignored.append("edit \(item.brief): not an object"); continue }
                    let dict = Dictionary(pairs, uniquingKeysWith: { first, _ in first })
                    guard let rawID = dict["id"], let id = validID(rawID) else {
                        ops.ignored.append("edit: id \(dict["id"]?.brief ?? "missing") is not a fact id in 1…\(factCount)"); continue
                    }
                    guard case .string(let text)? = dict["text"] else { ops.ignored.append("edit [\(id)]: text missing or not a string"); continue }
                    ops.edit.append(Edit(id: id, text: text))
                }
            case "add":
                guard case .array(let items) = field else { ops.ignored.append("add: not an array"); continue }
                for item in items {
                    guard case .object(let pairs) = item else { ops.ignored.append("add \(item.brief): not an object"); continue }
                    let dict = Dictionary(pairs, uniquingKeysWith: { first, _ in first })
                    guard case .string(let text)? = dict["text"] else { ops.ignored.append("add: text missing or not a string"); continue }
                    var after: Int? = nil
                    if let rawAfter = dict["after"] {
                        if case .null = rawAfter {} else if let id = validID(rawAfter) { after = id }
                        else { ops.ignored.append("add: after \(rawAfter.brief) is not a fact id; appended at the end") }
                    }
                    ops.add.append(Add(text: text, after: after))
                }
            default:
                ops.ignored.append("unknown field \"\(key)\"")
            }
        }
        return ops
    }

    /// First `{` to its matching `}`, skipping braces inside JSON strings.
    static func extractFirstObject(_ text: String) -> String? {
        let scalars = Array(text.unicodeScalars)
        guard let start = scalars.firstIndex(of: "{") else { return nil }
        var depth = 0, inString = false, escaped = false
        for index in start..<scalars.count {
            let c = scalars[index]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
                continue
            }
            if c == "\"" { inString = true }
            else if c == "{" { depth += 1 }
            else if c == "}" {
                depth -= 1
                if depth == 0 {
                    var view = String.UnicodeScalarView()
                    view.append(contentsOf: scalars[start...index])
                    return String(view)
                }
            }
        }
        return nil
    }

    /// Edit/add text normalisation: trim; internal line breaks → one space.
    /// nil = invalid (empty, or would read as a heading).
    static func normalize(_ text: String) -> String? {
        var out = ""
        var pendingBreak = false
        for scalar in text.unicodeScalars {
            if scalar == "\r" || scalar == "\n" { pendingBreak = true; continue }
            if pendingBreak { if !out.isEmpty, !out.hasSuffix(" ") { out += " " }; pendingBreak = false }
            out.unicodeScalars.append(scalar)
        }
        let trimmed = out.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        return trimmed
    }

    // MARK: - Application

    struct RetiredLine: Equatable {
        enum Op: String { case dropped, editedBefore = "edited (before)" }
        let op: Op
        let section: String
        /// The exact original line (prefix included, any `\r` included).
        let line: String
        /// A `\n` followed it in the profile.
        let followedByNewline: Bool
    }

    struct Result {
        let text: String
        let changed: Bool
        let sizeBefore: Int
        let sizeAfter: Int
        let retired: [RetiredLine]
        let appliedDrops: Int
        let appliedEdits: Int
        let appliedAdds: Int
        /// Characters of fact content removed by drops / by edits (old − new) / added.
        let charsDropped: Int
        let charsEditedDelta: Int
        let charsAdded: Int
        let ignored: [String]
        /// Added lines in final order (prefix included), for the preview report.
        let addedLines: [String]
        /// (old content, new content) per applied edit.
        let edits: [(old: String, new: String, section: String)]
        let drops: [(content: String, section: String)]
    }

    /// Deterministic application (§4.4, with the v6.1 amendment: no length
    /// rule — an edit applies whether or not it is shorter; the model is
    /// responsible for reducing the whole profile).
    func apply(_ ops: Operations) -> Result {
        let before = render()
        var ignored = ops.ignored
        let factIdx = factLineIndices
        let n = factIdx.count

        // Conflicts: an id that is both dropped and edited, or edited twice,
        // loses every op on it.
        var editCount: [Int: Int] = [:]
        for edit in ops.edit { editCount[edit.id, default: 0] += 1 }
        let dropSet = Set(ops.drop)
        var conflicted = Set<Int>()
        for (id, count) in editCount where count > 1 || dropSet.contains(id) { conflicted.insert(id) }
        for id in conflicted.sorted() { ignored.append("fact [\(id)]: conflicting operations (drop+edit or two edits) — all ignored") }

        var dropIDs = Set<Int>()
        for id in ops.drop where !conflicted.contains(id) { dropIDs.insert(id) }   // deduplicated

        var newContent: [Int: String] = [:]   // fact id → new content
        for edit in ops.edit where !conflicted.contains(edit.id) {
            guard let text = Self.normalize(edit.text) else {
                ignored.append("edit [\(edit.id)]: empty or starts with #"); continue
            }
            let old = lines[factIdx[edit.id - 1]].content
            if text == old { ignored.append("edit [\(edit.id)]: identical to the current text (no-op)"); continue }
            newContent[edit.id] = text
        }

        // Adds: normalised, de-duplicated against surviving facts and earlier
        // accepted adds (an add equal to a fact dropped in this reply is kept).
        var surviving = Set<String>()
        for id in 1...max(n, 1) where n > 0 && !dropIDs.contains(id) {
            surviving.insert(newContent[id] ?? lines[factIdx[id - 1]].content)
        }
        var acceptedAdds: [(text: String, after: Int?)] = []
        for add in ops.add {
            guard let text = Self.normalize(add.text) else { ignored.append("add: empty or starts with #"); continue }
            if surviving.contains(text) { ignored.append("add: duplicate of an existing fact or an earlier add"); continue }
            surviving.insert(text)
            acceptedAdds.append((text, add.after))
        }

        // Line endings for new lines: CRLF only if every delimited line uses it.
        let delimited = lines.indices.filter { $0 < lines.count - 1 || endsWithNewline }
        let crlf = !delimited.isEmpty && delimited.allSatisfy { lines[$0].raw.hasSuffix("\r") }

        // Build the new line list, keeping each surviving line's original index.
        struct Slot { var line: Line; var original: Int?; var removedHere: Bool = false }
        var slots: [Slot] = []
        var retired: [RetiredLine] = []
        var addsByAnchor: [Int: [String]] = [:]
        var addsAtEnd: [String] = []
        for add in acceptedAdds {
            if let after = add.after { addsByAnchor[after, default: []].append(add.text) } else { addsAtEnd.append(add.text) }
        }
        var appliedDrops = 0, appliedEdits = 0, charsDropped = 0, charsEditedDelta = 0, charsAdded = 0
        var editsReport: [(old: String, new: String, section: String)] = []
        var dropsReport: [(content: String, section: String)] = []
        var addedLines: [String] = []
        var factID = 0
        var removedOriginal = Set<Int>()
        func newLine(_ text: String, prefix: String, section: String) -> Line {
            Line(raw: prefix + text + (crlf ? "\r" : ""), kind: .fact, prefix: prefix, content: text, section: section, level: 0)
        }
        for (index, line) in lines.enumerated() {
            let followed = index < lines.count - 1 || endsWithNewline
            if line.kind != .fact { slots.append(Slot(line: line, original: index)); continue }
            factID += 1
            if dropIDs.contains(factID) {
                retired.append(RetiredLine(op: .dropped, section: line.section, line: line.raw, followedByNewline: followed))
                appliedDrops += 1; charsDropped += line.content.count
                dropsReport.append((line.content, line.section))
                removedOriginal.insert(index)
            } else if let text = newContent[factID] {
                retired.append(RetiredLine(op: .editedBefore, section: line.section, line: line.raw, followedByNewline: followed))
                var edited = line
                edited.content = text
                edited.raw = line.prefix + text + (line.raw.hasSuffix("\r") ? "\r" : "")
                slots.append(Slot(line: edited, original: nil))
                appliedEdits += 1; charsEditedDelta += line.content.count - text.count
                editsReport.append((line.content, text, line.section))
            } else {
                slots.append(Slot(line: line, original: index))
            }
            for text in addsByAnchor[factID] ?? [] {
                let added = newLine(text, prefix: line.prefix, section: line.section)
                slots.append(Slot(line: added, original: nil))
                charsAdded += text.count; addedLines.append(added.raw)
            }
        }
        let lastSection = lines.last(where: { $0.kind == .heading })?.content ?? ""
        for text in addsAtEnd {
            let added = newLine(text, prefix: "- ", section: lastSection)
            slots.append(Slot(line: added, original: nil))
            charsAdded += text.count; addedLines.append(added.raw)
        }

        // Headings whose section lost every fact (it had at least one before,
        // has none and no non-empty subsection now) go — structure, not retired.
        func factsUnder(_ list: [(kind: Kind, level: Int)], _ at: Int) -> Int {
            let level = list[at].level
            var count = 0
            var i = at + 1
            while i < list.count {
                if list[i].kind == .heading && list[i].level <= level { break }
                if list[i].kind == .fact { count += 1 }
                i += 1
            }
            return count
        }
        let beforeShape = lines.map { (kind: $0.kind, level: $0.level) }
        var changedAny = true
        while changedAny {
            changedAny = false
            let afterShape = slots.map { (kind: $0.line.kind, level: $0.line.level) }
            for (position, slot) in slots.enumerated() where slot.line.kind == .heading {
                guard let original = slot.original, factsUnder(beforeShape, original) > 0,
                      factsUnder(afterShape, position) == 0 else { continue }
                removedOriginal.insert(original)
                slots.remove(at: position)
                changedAny = true
                break
            }
        }

        // Blank runs created by removals collapse to one; leading/trailing
        // blanks created by removals are trimmed. Original runs stay as they were.
        func removedBetween(_ a: Int?, _ b: Int?) -> Bool {
            guard let a, let b else { return true }
            return (a + 1..<b).contains { removedOriginal.contains($0) }
        }
        var compact: [Slot] = []
        for slot in slots {
            if slot.line.kind == .blank, let previous = compact.last, previous.line.kind == .blank,
               removedBetween(previous.original, slot.original) {
                continue
            }
            compact.append(slot)
        }
        while let first = compact.first, first.line.kind == .blank, let original = first.original,
              (0..<original).contains(where: { removedOriginal.contains($0) }) {
            compact.removeFirst()
        }
        while let last = compact.last, last.line.kind == .blank, let original = last.original,
              (original + 1..<lines.count).contains(where: { removedOriginal.contains($0) }) {
            compact.removeLast()
        }

        let result = UserProfileDocument(lines: compact.map(\.line), endsWithNewline: endsWithNewline)
        let text = result.render()
        return Result(text: text, changed: text != before, sizeBefore: before.count, sizeAfter: text.count,
                      retired: retired, appliedDrops: appliedDrops, appliedEdits: appliedEdits,
                      appliedAdds: addedLines.count, charsDropped: charsDropped, charsEditedDelta: charsEditedDelta,
                      charsAdded: charsAdded, ignored: ignored, addedLines: addedLines,
                      edits: editsReport, drops: dropsReport)
    }
}

// MARK: - Strict JSON

/// A small strict JSON parser: keeps integer lexemes apart from other
/// numbers (`3.0`, `3e0` are not ids), preserves object field order and
/// reports duplicate keys — the maintenance reply needs all three, and
/// Foundation's parsers differ between Darwin and Linux on them.
enum StrictJSON {
    indirect enum Value: Equatable {
        case object([(String, Value)])
        case array([Value])
        case string(String)
        case int(Int)
        case number(String)
        case bool(Bool)
        case null

        static func == (lhs: Value, rhs: Value) -> Bool {
            switch (lhs, rhs) {
            case (.object(let a), .object(let b)):
                return a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
            case (.array(let a), .array(let b)): return a == b
            case (.string(let a), .string(let b)): return a == b
            case (.int(let a), .int(let b)): return a == b
            case (.number(let a), .number(let b)): return a == b
            case (.bool(let a), .bool(let b)): return a == b
            case (.null, .null): return true
            default: return false
            }
        }

        var brief: String {
            switch self {
            case .object: return "{…}"
            case .array: return "[…]"
            case .string(let s): return "\"\(s.prefix(20))\""
            case .int(let i): return String(i)
            case .number(let n): return n
            case .bool(let b): return b ? "true" : "false"
            case .null: return "null"
            }
        }
    }

    enum ParseError: Error, CustomStringConvertible {
        case unexpectedEnd, unexpected(Character, Int), duplicateKey(String), badEscape, badNumber, trailingData, tooDeep
        var description: String {
            switch self {
            case .unexpectedEnd: return "unexpected end"
            case .unexpected(let c, let at): return "unexpected '\(c)' at \(at)"
            case .duplicateKey(let k): return "duplicate key \"\(k)\""
            case .badEscape: return "invalid escape"
            case .badNumber: return "invalid number"
            case .trailingData: return "data after the value"
            case .tooDeep: return "nesting too deep"
            }
        }
    }

    static func parse(_ text: String) throws -> Value {
        var parser = Parser(scalars: Array(text.unicodeScalars))
        let value = try parser.value(depth: 0)
        parser.skipSpace()
        guard parser.at == parser.scalars.count else { throw ParseError.trailingData }
        return value
    }

    private struct Parser {
        let scalars: [Unicode.Scalar]
        var at = 0

        mutating func skipSpace() {
            while at < scalars.count, [" ", "\t", "\n", "\r"].contains(scalars[at]) { at += 1 }
        }

        mutating func expect(_ literal: String) throws {
            for scalar in literal.unicodeScalars {
                guard at < scalars.count else { throw ParseError.unexpectedEnd }
                guard scalars[at] == scalar else { throw ParseError.unexpected(Character(scalars[at]), at) }
                at += 1
            }
        }

        mutating func value(depth: Int) throws -> Value {
            guard depth < 64 else { throw ParseError.tooDeep }
            skipSpace()
            guard at < scalars.count else { throw ParseError.unexpectedEnd }
            switch scalars[at] {
            case "{":
                at += 1
                var fields: [(String, Value)] = []
                var seen = Set<String>()
                skipSpace()
                if at < scalars.count, scalars[at] == "}" { at += 1; return .object(fields) }
                while true {
                    skipSpace()
                    guard at < scalars.count else { throw ParseError.unexpectedEnd }
                    guard scalars[at] == "\"" else { throw ParseError.unexpected(Character(scalars[at]), at) }
                    let key = try string()
                    guard seen.insert(key).inserted else { throw ParseError.duplicateKey(key) }
                    skipSpace()
                    try expect(":")
                    fields.append((key, try value(depth: depth + 1)))
                    skipSpace()
                    guard at < scalars.count else { throw ParseError.unexpectedEnd }
                    if scalars[at] == "," { at += 1; continue }
                    if scalars[at] == "}" { at += 1; return .object(fields) }
                    throw ParseError.unexpected(Character(scalars[at]), at)
                }
            case "[":
                at += 1
                var items: [Value] = []
                skipSpace()
                if at < scalars.count, scalars[at] == "]" { at += 1; return .array(items) }
                while true {
                    items.append(try value(depth: depth + 1))
                    skipSpace()
                    guard at < scalars.count else { throw ParseError.unexpectedEnd }
                    if scalars[at] == "," { at += 1; continue }
                    if scalars[at] == "]" { at += 1; return .array(items) }
                    throw ParseError.unexpected(Character(scalars[at]), at)
                }
            case "\"": return .string(try string())
            case "t": try expect("true"); return .bool(true)
            case "f": try expect("false"); return .bool(false)
            case "n": try expect("null"); return .null
            default: return try number()
            }
        }

        mutating func string() throws -> String {
            at += 1   // opening quote
            var out = String.UnicodeScalarView()
            while true {
                guard at < scalars.count else { throw ParseError.unexpectedEnd }
                let c = scalars[at]; at += 1
                if c == "\"" { return String(out) }
                if c.value < 0x20 { throw ParseError.unexpected(Character(c), at - 1) }
                guard c == "\\" else { out.append(c); continue }
                guard at < scalars.count else { throw ParseError.unexpectedEnd }
                let e = scalars[at]; at += 1
                switch e {
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "/": out.append("/")
                case "b": out.append("\u{08}")
                case "f": out.append("\u{0C}")
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                case "u":
                    var code = try hex4()
                    if (0xD800...0xDBFF).contains(code) {
                        guard at + 1 < scalars.count, scalars[at] == "\\", scalars[at + 1] == "u" else { throw ParseError.badEscape }
                        at += 2
                        let low = try hex4()
                        guard (0xDC00...0xDFFF).contains(low) else { throw ParseError.badEscape }
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    }
                    guard let scalar = Unicode.Scalar(code) else { throw ParseError.badEscape }
                    out.append(scalar)
                default: throw ParseError.badEscape
                }
            }
        }

        mutating func hex4() throws -> UInt32 {
            guard at + 4 <= scalars.count else { throw ParseError.unexpectedEnd }
            var value: UInt32 = 0
            for _ in 0..<4 {
                guard let digit = Int(String(scalars[at]), radix: 16) else { throw ParseError.badEscape }
                value = value * 16 + UInt32(digit); at += 1
            }
            return value
        }

        mutating func number() throws -> Value {
            let start = at
            if at < scalars.count, scalars[at] == "-" { at += 1 }
            guard at < scalars.count, ("0"..."9").contains(scalars[at]) else { throw ParseError.badNumber }
            if scalars[at] == "0" { at += 1 } else { while at < scalars.count, ("0"..."9").contains(scalars[at]) { at += 1 } }
            var integral = true
            if at < scalars.count, scalars[at] == "." {
                integral = false; at += 1
                guard at < scalars.count, ("0"..."9").contains(scalars[at]) else { throw ParseError.badNumber }
                while at < scalars.count, ("0"..."9").contains(scalars[at]) { at += 1 }
            }
            if at < scalars.count, scalars[at] == "e" || scalars[at] == "E" {
                integral = false; at += 1
                if at < scalars.count, scalars[at] == "+" || scalars[at] == "-" { at += 1 }
                guard at < scalars.count, ("0"..."9").contains(scalars[at]) else { throw ParseError.badNumber }
                while at < scalars.count, ("0"..."9").contains(scalars[at]) { at += 1 }
            }
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars[start..<at])
            let lexeme = String(view)
            if integral, let value = Int(lexeme) { return .int(value) }
            return .number(lexeme)
        }
    }
}
