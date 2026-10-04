import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// The append-only record of every fact profile maintenance removed or
/// shortened (USER_CONTEXT_EDIT_OPS_PLAN §9): word for word, so nothing the
/// model drops is lost. JSON Lines, one record per line, owner-only, never
/// trimmed or rotated; `/deleteuserdata` is the only removal.
///
/// `.jsonl`, not `.txt` (a v0.2.48 `backfillSidecars` deletes `*.txt` without
/// a sibling `.json`) and not `.json` (`reconcileUntrackedRawFiles`), so it
/// survives every archive cleanup path of current and older binaries.
enum RetiredUserFacts {
    static let fileName = "retired_user_facts.jsonl"

    static var url: URL {
        StoragePaths.dataRoot.appendingPathComponent("archive", isDirectory: true).appendingPathComponent(fileName)
    }

    struct Record: Equatable {
        let at: String
        let source: String
        let op: String
        let section: String
        let line: String
        let followedByNewline: Bool

        /// The original bytes this record preserves.
        var originalText: String { line + (followedByNewline ? "\n" : "") }

        func jsonLine() throws -> Data {
            let object: [String: Any] = ["v": 1, "at": at, "source": source, "op": op,
                                         "section": section, "line": line, "nl": followedByNewline]
            var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            data.append(0x0A)
            return data
        }
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone.current
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func records(from retired: [UserProfileDocument.RetiredLine], pass: Int, at date: Date) -> [Record] {
        let stamp = timestamp(date)
        return retired.map {
            Record(at: stamp, source: "maintenance pass \(pass)", op: $0.op.rawValue,
                   section: $0.section, line: $0.line, followedByNewline: $0.followedByNewline)
        }
    }

    struct AppendError: Error, LocalizedError {
        let description: String
        var errorDescription: String? { description }
    }

    /// Appends one batch as complete lines in one write sequence, then fsync
    /// (and a directory fsync when the file was created). A torn earlier tail
    /// (no final `\n`) is first closed with a newline so this batch starts on
    /// its own line; the torn fragment is kept and skipped by readers. The
    /// profile swap happens only after this returns.
    static func append(_ records: [Record], to fileURL: URL = url) throws {
        guard !records.isEmpty else { return }
        var payload = Data()
        for record in records { payload.append(try record.jsonLine()) }
        let directory = fileURL.deletingLastPathComponent()
        try PrivateStorage.ensureDirectory(directory)
        let existed = FileManager.default.fileExists(atPath: fileURL.path)
        let handle = try PrivateStorage.openForAppend(fileURL)
        defer { try? handle.close() }
        let fd = handle.fileDescriptor
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw AppendError(description: "stat \(fileURL.path): \(String(cString: strerror(errno)))") }
        guard (st.st_mode & S_IFMT) == S_IFREG else { throw AppendError(description: "\(fileURL.path) is not a regular file") }
        if st.st_size > 0, try lastByte(of: fileURL) != 0x0A {
            payload.insert(0x0A, at: 0)
        }
        try payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw AppendError(description: "write \(fileURL.path): \(String(cString: strerror(errno)))")
                }
                offset += written
            }
        }
        guard fsync(fd) == 0 else { throw AppendError(description: "fsync \(fileURL.path): \(String(cString: strerror(errno)))") }
        if !existed { try PrivateStorage.fsyncDirectory(directory.path) }
    }

    private static func lastByte(of fileURL: URL) throws -> UInt8? {
        let reader = try FileHandle(forReadingFrom: fileURL)
        defer { try? reader.close() }
        let end = try reader.seekToEnd()
        guard end > 0 else { return nil }
        try reader.seek(toOffset: end - 1)
        return try reader.read(upToCount: 1)?.first
    }

    /// Tolerant reader: valid records in order, plus the number of torn or
    /// undecodable lines skipped.
    static func read(from fileURL: URL = url) throws -> (records: [Record], skipped: Int) {
        let data = try Data(contentsOf: fileURL)
        var records: [Record] = []
        var skipped = 0
        for segment in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(segment)) as? [String: Any],
                  (object["v"] as? Int) == 1,
                  let at = object["at"] as? String, let source = object["source"] as? String,
                  let op = object["op"] as? String, let section = object["section"] as? String,
                  let line = object["line"] as? String, let nl = object["nl"] as? Bool else {
                skipped += 1; continue
            }
            records.append(Record(at: at, source: source, op: op, section: section, line: line, followedByNewline: nl))
        }
        return (records, skipped)
    }

    /// True when the file exists and is non-empty (the §9.3 prompt bullet).
    /// A plain stat per call: always current, no cache to invalidate.
    static func hasRecords(at fileURL: URL = url) -> Bool {
        var st = stat()
        guard lstat(fileURL.path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFREG && st.st_size > 0
    }
}
