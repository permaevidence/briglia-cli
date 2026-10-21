import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// One-time restore of summaries shortened by 0.2.48–0.2.57's destructive
/// demotion (KEEP_SUMMARIES_PLAN v5 §6). Only the provably exact case is
/// accepted; everything else stays a pointer. Reads only Briglia-written
/// snapshot files reached from a record's own validated reference, never
/// more than `maxFileBytes`, and never searches raw text for structure.
enum PruneSummaryRestore {
    static let maxFileBytes = 8 * 1024 * 1024
    static let maxPassBytes = 32 * 1024 * 1024

    static let summaryMarker = "Prior pruning summary:"
    static let coveragePrefix = "Prior pruning summary coverage: "
    static let headerPrefix = "=== MESSAGE "
    static let endPrefix = "BRIGLIA SNAPSHOT END "
    static let idListLine = "Removed message IDs:"
    static let callListLine = "Removed active-turn call IDs:"
    /// The fixed preamble of a demotion snapshot (`PruneArchiveStore.write`
    /// with a lead note): header, lead note, five fixed lines, then the list.
    static let idListLineIndex = 7

    struct Refusal: Error, Equatable {
        let reason: String
        init(_ reason: String) { self.reason = reason }
    }

    /// A snapshot that passed rules 2 (file part), 3 and 4: every genuine
    /// boundary located, blocks indexed by message id.
    struct IndexedSnapshot {
        let reference: PruneArchiveReference
        let bytes: [UInt8]
        /// Byte offset where each content line starts, plus one past the end.
        let lineStarts: [Int]
        /// Message id → content-line index range of its durable block.
        let blocks: [UUID: Range<Int>]

        func line(_ index: Int) -> ArraySlice<UInt8> {
            bytes[lineStarts[index]..<(lineStarts[index + 1] - 1)]
        }
    }

    /// File size without reading the body (budget check before any read).
    static func fileSize(_ reference: PruneArchiveReference, directory: URL = PruneArchiveStore.root) -> Int? {
        var st = stat()
        guard lstat(directory.appendingPathComponent(reference.basename).path, &st) == 0,
              st.st_mode & S_IFMT == S_IFREG else { return nil }
        return Int(st.st_size)
    }

    /// Reads (size-checked first) and indexes one demotion snapshot.
    static func index(_ reference: PruneArchiveReference, directory: URL = PruneArchiveStore.root) -> Result<IndexedSnapshot, Refusal> {
        guard PruneArchiveReference.validBasename(reference.basename) else { return .failure(Refusal("invalid basename")) }
        guard let size = fileSize(reference, directory: directory) else { return .failure(Refusal("missing")) }
        guard size <= maxFileBytes else { return .failure(Refusal("over the per-file budget")) }
        guard PruneArchiveStore.isCompleteSnapshot(reference, directory: directory) else { return .failure(Refusal("incomplete")) }
        let path = directory.appendingPathComponent(reference.basename).path
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return .failure(Refusal("unreadable")) }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size <= maxFileBytes else {
            return .failure(Refusal("not a regular file within the budget"))
        }
        var bytes = [UInt8](repeating: 0, count: Int(st.st_size))
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeMutableBytes { raw in read(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { return .failure(Refusal("short read")) }
            offset += n
        }
        return index(bytes: bytes, reference: reference)
    }

    /// Test-only: how many snapshot files were indexed (read-once checks).
    nonisolated(unsafe) static var indexCountForTesting = 0

    /// Rules 3 and 4 on the bytes of one snapshot.
    static func index(bytes: [UInt8], reference: PruneArchiveReference) -> Result<IndexedSnapshot, Refusal> {
        indexCountForTesting += 1
        // Rule 3: the whole file is strict UTF-8 (a lossy decode would change bytes).
        guard Array(String(decoding: bytes, as: UTF8.self).utf8) == bytes else { return .failure(Refusal("not strict UTF-8")) }
        // The writer terminates every line, the end marker included, with
        // one LF: the final empty component after it is not a line.
        guard bytes.last == 10 else { return .failure(Refusal("no terminating newline")) }
        var starts = [0]
        for (i, byte) in bytes.enumerated() where byte == 10 { starts.append(i + 1) }
        let lineCount = starts.count - 1
        func text(_ i: Int) -> String { String(decoding: bytes[starts[i]..<(starts[i + 1] - 1)], as: UTF8.self) }
        func hasPrefix(_ i: Int, _ prefix: String) -> Bool {
            let p = Array(prefix.utf8)
            let start = starts[i], end = starts[i + 1] - 1
            return end - start >= p.count && Array(bytes[start..<(start + p.count)]) == p
        }
        guard lineCount > idListLineIndex + 1 else { return .failure(Refusal("too short")) }
        // Header and lead note.
        let headerPrefix0 = "BRIGLIA SNAPSHOT 1 "
        let first = text(0)
        guard first.hasPrefix(headerPrefix0),
              let header = try? JSONDecoder().decode(PruneArchiveStore.Header.self, from: Data(first.dropFirst(headerPrefix0.count).utf8)),
              header.version == 1, header.id == reference.id, header.messages >= 1 else { return .failure(Refusal("header")) }
        guard text(1) == PruneSummaryRetention.snapshotLeadNote else { return .failure(Refusal("not a demotion snapshot")) }
        // The id list sits in the fixed preamble, before any raw text.
        guard text(idListLineIndex) == idListLine else { return .failure(Refusal("id list not at its fixed place")) }
        let listEnd = idListLineIndex + 1 + header.messages
        guard listEnd < lineCount, text(listEnd) == callListLine else { return .failure(Refusal("id list length")) }
        var ids: [UUID] = []
        for i in (idListLineIndex + 1)..<listEnd {
            let line = text(i)
            guard let id = UUID(uuidString: line), id.uuidString == line else { return .failure(Refusal("id list entry")) }
            ids.append(id)
        }
        guard Set(ids).count == ids.count else { return .failure(Refusal("duplicate id in list")) }
        // Rule 4: whole-file boundary inventory, before any block is split.
        // Malformed candidates stay in the count.
        var headers: [Int] = []
        var ends: [Int] = []
        for i in 0..<lineCount {
            if hasPrefix(i, headerPrefix) { headers.append(i) }
            if hasPrefix(i, endPrefix) { ends.append(i) }
        }
        guard headers.count == header.messages else { return .failure(Refusal("boundary count")) }
        guard ends.count == 1, ends[0] == lineCount - 1, text(ends[0]) == endPrefix + header.id.uuidString else {
            return .failure(Refusal("end inventory"))
        }
        var blocks: [UUID: Range<Int>] = [:]
        for (k, line) in headers.enumerated() {
            guard line > listEnd else { return .failure(Refusal("boundary before the preamble ends")) }
            let expected = "=== MESSAGE \(k + 1) | view=durable | id=\(ids[k].uuidString) | "
            guard hasPrefix(line, expected) else { return .failure(Refusal("boundary order/shape")) }
            let next = k + 1 < headers.count ? headers[k + 1] : ends[0]
            blocks[ids[k]] = (line + 1)..<next
        }
        return .success(IndexedSnapshot(reference: reference, bytes: bytes, lineStarts: starts, blocks: blocks))
    }

    /// The coverage line the writer emits for `coverage` (byte-for-byte).
    static func coverageLine(_ coverage: PruneSummaryCoverage) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let files = String(decoding: (try? encoder.encode(coverage.files)) ?? Data("[]".utf8), as: UTF8.self)
        return coveragePrefix + PruneSummaryRetention.span(coverage) + (coverage.complete ? "" : " (approx.)") + "; files: " + files
    }

    /// Rule 5 inside one verified block: the exact summary bytes.
    static func recover(messageID: UUID, coverage: PruneSummaryCoverage, from snapshot: IndexedSnapshot) -> Result<String, Refusal> {
        guard coverage.complete, coverage.isValid else { return .failure(Refusal("coverage not complete")) }
        guard let block = snapshot.blocks[messageID] else { return .failure(Refusal("id not listed")) }
        let marker = Array(summaryMarker.utf8), prefix = Array(coveragePrefix.utf8)
        var summaryLines: [Int] = [], coverageLines: [Int] = []
        for i in block {
            let line = snapshot.line(i)
            if Array(line) == marker { summaryLines.append(i) }
            if line.count >= prefix.count && Array(line.prefix(prefix.count)) == prefix { coverageLines.append(i) }
        }
        guard summaryLines.count == 1, coverageLines.count == 1, coverageLines[0] > summaryLines[0] else {
            return .failure(Refusal("marker count"))
        }
        guard Array(snapshot.line(coverageLines[0])) == Array(coverageLine(coverage).utf8) else {
            return .failure(Refusal("coverage line mismatch"))
        }
        // Exactly the bytes between the marker line and the coverage line,
        // minus the single LF the writer added after the summary.
        let start = snapshot.lineStarts[summaryLines[0] + 1]
        let end = snapshot.lineStarts[coverageLines[0]]
        guard end - start >= 2, snapshot.bytes[end - 1] == 10 else { return .failure(Refusal("empty summary")) }
        return .success(String(decoding: snapshot.bytes[start..<(end - 1)], as: UTF8.self))
    }
}
