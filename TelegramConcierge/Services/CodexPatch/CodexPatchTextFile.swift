import Foundation

extension CodexPatch {

    /// Port of `text_file.rs` plus Briglia's BOM handling (plan §6.3).
    struct SourceFile {
        enum LineEnding: Equatable {
            case lf, crlf, cr
            var bytes: [UInt8] {
                switch self { case .lf: return [0x0A]; case .crlf: return [0x0D, 0x0A]; case .cr: return [0x0D] }
            }
        }

        struct Line {
            var text: String
            var ending: LineEnding?
        }

        private(set) var lines: [Line]
        let preferredEnding: LineEnding
        /// Briglia divergence: a UTF-8 BOM is stripped before splitting and
        /// restored on write (Codex keeps U+FEFF as part of line 1).
        let hadBOM: Bool

        enum DecodeError: Error, Equatable, CustomStringConvertible {
            case binary, invalidUTF8
            var description: String {
                switch self {
                case .binary: return "binary file (NUL byte in the first 8 KiB)"
                case .invalidUTF8: return "not valid UTF-8 text"
                }
            }
        }

        static let bom: [UInt8] = [0xEF, 0xBB, 0xBF]

        /// Bytes in: BOM recorded and stripped, NUL in the first 8 KiB refused
        /// as binary, invalid UTF-8 refused.
        static func decode(_ data: Data) throws -> SourceFile {
            var bytes = [UInt8](data)
            if bytes.prefix(8192).contains(0) { throw DecodeError.binary }
            let hadBOM = bytes.starts(with: bom)
            if hadBOM { bytes.removeFirst(3) }
            // Strict validation (no replacement characters): decoding must
            // round-trip byte for byte.
            let text = String(decoding: bytes, as: UTF8.self)
            guard text.utf8.elementsEqual(bytes) else { throw DecodeError.invalidUTF8 }
            return parse(text, hadBOM: hadBOM)
        }

        /// `SourceFile::parse`: split on `\r\n`, `\r`, `\n`, each line keeping
        /// its ending; the first ending seen is preferred (LF if none). Works
        /// on UTF-8 bytes; the separators are ASCII so slices stay valid.
        static func parse(_ contents: String, hadBOM: Bool = false) -> SourceFile {
            let bytes = Array(contents.utf8)
            var lines: [Line] = []
            var preferred: LineEnding?
            var lineStart = 0
            var cursor = 0
            while cursor < bytes.count {
                let ending: LineEnding
                let length: Int
                switch bytes[cursor] {
                case 0x0D where cursor + 1 < bytes.count && bytes[cursor + 1] == 0x0A: ending = .crlf; length = 2
                case 0x0D: ending = .cr; length = 1
                case 0x0A: ending = .lf; length = 1
                default: cursor += 1; continue
                }
                if preferred == nil { preferred = ending }
                lines.append(Line(text: String(decoding: bytes[lineStart..<cursor], as: UTF8.self), ending: ending))
                cursor += length
                lineStart = cursor
            }
            if lineStart < bytes.count {
                lines.append(Line(text: String(decoding: bytes[lineStart...], as: UTF8.self), ending: nil))
            }
            return SourceFile(lines: lines, preferredEnding: preferred ?? .lf, hadBOM: hadBOM)
        }

        var lineTexts: [String] { lines.map(\.text) }

        /// `apply_replacements`: unchanged lines keep their bytes, new lines
        /// get the preferred ending, then every line gets an ending.
        mutating func applyReplacements(_ replacements: [Replacement]) {
            var out: [Line] = []
            out.reserveCapacity(lines.count)
            var sourceIndex = 0
            // Callers refuse overlaps first (`overlapError`); the clamps only
            // keep a violated precondition from trapping.
            for r in replacements {
                let upto = max(sourceIndex, min(r.start, lines.count))
                out.append(contentsOf: lines[sourceIndex..<upto])
                sourceIndex = max(upto, min(r.start + r.oldLength, lines.count))
                out.append(contentsOf: r.newLines.map { Line(text: $0, ending: preferredEnding) })
            }
            if sourceIndex < lines.count { out.append(contentsOf: lines[sourceIndex...]) }
            for i in out.indices where out[i].ending == nil { out[i].ending = preferredEnding }
            lines = out
        }

        /// `into_contents`, with the BOM restored when the source had one.
        func contents() -> Data {
            var data = Data()
            if hadBOM { data.append(contentsOf: Self.bom) }
            for line in lines {
                data.append(contentsOf: Array(line.text.utf8))
                if let e = line.ending { data.append(contentsOf: e.bytes) }
            }
            return data
        }

        /// Text form (no BOM) — for the secret-store path and tests.
        func text() -> String { String(decoding: contents().dropFirst(hadBOM ? 3 : 0), as: UTF8.self) }
    }

    /// Update result for one file (port of `derive_new_contents_from_chunks`).
    struct DerivedUpdate {
        var newContents: Data
        var fuzz: FuzzLevel
    }

    /// Pure function: original bytes + chunks → new bytes. `path` is the text
    /// used in Codex's error messages.
    static func deriveNewContents(original: Data, path: String, chunks: [Chunk]) throws -> DerivedUpdate {
        var file = try SourceFile.decode(original)
        let plan = try computeReplacements(originalLines: file.lineTexts, path: path, chunks: chunks)
        if let overlap = overlapError(plan.replacements, path: path) { throw overlap }
        file.applyReplacements(plan.replacements)
        return DerivedUpdate(newContents: file.contents(), fuzz: plan.fuzz)
    }
}
