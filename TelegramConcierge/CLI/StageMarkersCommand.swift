import ArgumentParser
import Foundation

/// Hidden reader for the stage-marker diagnostics
/// (`~/.local/share/briglia/logs/stage-markers.log`, see StageMarkers.swift).
/// Read-only: it never creates or writes the log.
///
///     briglia __stage-markers            last 40 records
///     briglia __stage-markers --last 200
///     briglia __stage-markers --unclosed stages entered but never exited
///                                        (the most recent run of each pid)
struct StageMarkersCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__stage-markers",
        abstract: "Internal: print the latest tool-stage diagnostics records.",
        shouldDisplay: false
    )

    @Option(name: .customLong("last"), help: "How many records to print.")
    var last: Int = 40

    @Flag(name: .customLong("unclosed"), help: "Print only stages that were entered and never exited.")
    var unclosed = false

    func run() throws {
        let url = StageMarkers.logURL
        print("Stage markers: \(url.path)")
        let read = StageMarkersReader.readLog(url)
        for problem in read.readErrors { print("READ ERROR: \(problem)") }
        let lines = read.lines
        guard !lines.isEmpty || read.invalidEncoding > 0 else {
            print(read.readErrors.isEmpty ? "(no records yet)" : "(no readable records)")
            return
        }
        var check = StageMarkersReader.integrity(lines)
        check.invalidEncoding = read.invalidEncoding
        print(check.summary)
        if unclosed {
            let open = StageMarkersReader.unclosed(lines)
            print(open.isEmpty ? "(no unclosed stages)" : open.joined(separator: "\n"))
        } else {
            print(lines.suffix(max(1, last)).joined(separator: "\n"))
        }
        if lines.contains(where: { $0.contains("\"stall_suspected\"") }) {
            print(Self.stallNote)
        }
    }

    /// /stop visibility (Codex Q3): what a stall report does and does not mean.
    static let stallNote = "Note: a stall_suspected record means a stage stayed open longer than the reporting threshold — not that it is proven hung. Memory archiving (archive.wait / archive.phase.*) can legitimately take minutes; its timeouts and retries are unchanged and nothing is cancelled by the report."
}

enum StageMarkersReader {
    /// The log (rotated `.1` first, then current) as newline-delimited
    /// lines. Decoding is PER LINE: a line whose bytes are not valid UTF-8
    /// (a write cut inside a multi-byte character) is counted in
    /// `invalidEncoding` and left out, never hiding the valid lines around
    /// it (Codex round 2). A file that exists but cannot be read is reported
    /// in `readErrors`, never treated as empty. Absent files are normal.
    struct LogRead {
        var lines: [String] = []
        var invalidEncoding = 0
        var readErrors: [String] = []
    }

    static func readLog(_ url: URL) -> LogRead {
        var result = LogRead()
        for file in [URL(fileURLWithPath: url.path + ".1"), url] {
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let data: Data
            do {
                data = try Data(contentsOf: file)
            } catch {
                result.readErrors.append("\(file.path): \(error.localizedDescription)")
                continue
            }
            let (lines, invalid) = splitLines(data)
            result.lines += lines
            result.invalidEncoding += invalid
        }
        return result
    }

    /// Splits bytes at newlines and decodes each line strictly.
    static func splitLines(_ data: Data) -> (lines: [String], invalid: Int) {
        var lines: [String] = []
        var invalid = 0
        for chunk in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if let line = String(data: Data(chunk), encoding: .utf8) {
                lines.append(line)
            } else {
                invalid += 1
            }
        }
        return (lines, invalid)
    }

    /// Enter records with no matching exit (same pid + id). Stall reports
    /// for the same stage are kept too, so the output answers "where did it
    /// stop, and was that reported".
    static func unclosed(_ lines: [String]) -> [String] {
        var openByKey: [String: String] = [:]
        var order: [String] = []
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ev = obj["ev"] as? String else { continue }
            let key = "\(obj["pid"] ?? "?")/\(obj["id"] ?? "?")"
            switch ev {
            case "enter":
                openByKey[key] = line
                order.append(key)
            case "exit":
                openByKey.removeValue(forKey: key)
            default:
                break
            }
        }
        return order.compactMap { openByKey.removeValue(forKey: $0) }
    }

    struct Integrity {
        var records = 0
        /// Lines that are not a JSON record: a partial write, or a fragment.
        var malformed = 0
        /// Records missing between consecutive sequence numbers of a run.
        var missing = 0
        /// Losses the writer itself reported in later records.
        var reportedUnwritten = 0
        var reportedDropped = 0
        /// Lines that are not even valid UTF-8 (set by the caller from
        /// `readLog`); they are damaged records too.
        var invalidEncoding = 0

        var isClean: Bool {
            malformed == 0 && missing == 0 && reportedUnwritten == 0 && reportedDropped == 0 && invalidEncoding == 0
        }

        var summary: String {
            if isClean { return "Integrity: \(records) records, no gaps, no malformed lines" }
            return "Integrity: \(records) records; LOSS DETECTED: \(missing) missing (sequence gaps), \(malformed + invalidEncoding) damaged line(s) (\(invalidEncoding) invalid UTF-8), \(reportedUnwritten) reported unwritten (write errors), \(reportedDropped) reported dropped (queue full). Unwritten records may be on stderr as [StageMarkers-unwritten]."
        }
    }

    /// Checks the file for silent loss. Sequence numbers are per process
    /// run (pid); a pid whose sequence goes backwards is a new run (pids are
    /// reused, e.g. across container restarts). Gaps before a run's first
    /// surviving record (rotated away) are not counted.
    static func integrity(_ lines: [String]) -> Integrity {
        var result = Integrity()
        var lastSeq: [String: Int] = [:]
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let seq = obj["seq"] as? Int else {
                result.malformed += 1
                continue
            }
            result.records += 1
            let pid = "\(obj["pid"] ?? "?")"
            if let last = lastSeq[pid], seq > last + 1 { result.missing += seq - last - 1 }
            lastSeq[pid] = seq
            result.reportedUnwritten += obj["write_failed_before"] as? Int ?? 0
            result.reportedDropped += obj["dropped_before"] as? Int ?? 0
        }
        return result
    }

    /// One read-only line for `briglia doctor`.
    static func doctorLine() -> String {
        guard StageMarkers.enabled else {
            return "tool stage markers disabled (BRIGLIA_STAGE_MARKERS=0)"
        }
        let path = StageMarkers.logURL.path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return "tool stage markers: \(path) (no records yet); `briglia __stage-markers` prints the latest"
        }
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let modified = (attrs[.modificationDate] as? Date).map {
            ISO8601DateFormatter().string(from: $0)
        } ?? "?"
        var loss = ""
        let read = readLog(StageMarkers.logURL)
        var check = integrity(read.lines)
        check.invalidEncoding = read.invalidEncoding
        if !check.isClean {
            loss = "; LOSS DETECTED (\(check.missing) missing, \(check.malformed + check.invalidEncoding) damaged incl. \(check.invalidEncoding) invalid UTF-8, \(check.reportedUnwritten) unwritten, \(check.reportedDropped) dropped)"
        }
        if !read.readErrors.isEmpty {
            loss += "; READ ERROR: \(read.readErrors.joined(separator: "; "))"
        }
        return "tool stage markers: \(path) (\(size / 1024) KB, last write \(modified))\(loss); `briglia __stage-markers --unclosed` shows stages that never finished"
    }
}
