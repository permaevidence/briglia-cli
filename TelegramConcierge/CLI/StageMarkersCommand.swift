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
        return "tool stage markers: \(path) (\(size / 1024) KB, last write \(modified)); `briglia __stage-markers --unclosed` shows stages that never finished"
    }
}
