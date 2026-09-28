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
        let rotated = URL(fileURLWithPath: url.path + ".1")
        var lines: [String] = []
        for file in [rotated, url] {
            if let text = try? String(contentsOf: file, encoding: .utf8) {
                lines += text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            }
        }
        guard !lines.isEmpty else {
            print("(no records yet)")
            return
        }
        print(StageMarkersReader.integrity(lines).summary)
        if unclosed {
            let open = StageMarkersReader.unclosed(lines)
            print(open.isEmpty ? "(no unclosed stages)" : open.joined(separator: "\n"))
        } else {
            print(lines.suffix(max(1, last)).joined(separator: "\n"))
        }
    }
}

enum StageMarkersReader {
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

        var isClean: Bool { malformed == 0 && missing == 0 && reportedUnwritten == 0 && reportedDropped == 0 }

        var summary: String {
            if isClean { return "Integrity: \(records) records, no gaps, no malformed lines" }
            return "Integrity: \(records) records; LOSS DETECTED: \(missing) missing (sequence gaps), \(malformed) malformed line(s), \(reportedUnwritten) reported unwritten (write errors), \(reportedDropped) reported dropped (queue full). Unwritten records may be on stderr as [StageMarkers-unwritten]."
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
        if let text = try? String(contentsOfFile: path, encoding: .utf8) {
            let check = integrity(text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init))
            if !check.isClean {
                loss = "; LOSS DETECTED (\(check.missing) missing, \(check.malformed) malformed, \(check.reportedUnwritten) unwritten, \(check.reportedDropped) dropped)"
            }
        }
        return "tool stage markers: \(path) (\(size / 1024) KB, last write \(modified))\(loss); `briglia __stage-markers --unclosed` shows stages that never finished"
    }
}
