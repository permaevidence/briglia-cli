import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

extension DiffPipeSelftest {

    // MARK: - D4: small diffs and the caps are unchanged

    static func smallDiffUnchanged(_ check: Check, dir: URL) async {
        let path = dir.appendingPathComponent("small.txt").path
        try? "a\nb\nc\n".write(toFile: path, atomically: true, encoding: .utf8)
        await FileTimeTracker.shared.recordRead(path: path)
        let run = await bounded(callBound) {
            await FilesystemTools.shared.editFile(path: path, oldString: "b", newString: "B").content
        }
        let diff = json(run.value ?? "")["diff"] as? String ?? ""
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false)
        let body = lines.dropFirst(2).joined(separator: "\n")
        check("D4a small edit: same headers and hunk as before",
              diff.hasPrefix("--- a/" + path) && lines.count > 2 && lines[1].hasPrefix("+++ b/" + path)
              && body == "@@ -1,3 +1,3 @@\n a\n-b\n+B\n c\n", diff)

        let old = (0..<600).map { "x\($0)" }.joined(separator: "\n") + "\n"
        let new = (0..<600).map { "y\($0)" }.joined(separator: "\n") + "\n"
        let medium = DiffUtil.unifiedDiff(old: old, new: new, path: "/m.txt") ?? ""
        let mediumLines = medium.split(separator: "\n", omittingEmptySubsequences: false)
        check("D4b line cap unchanged: 400 lines plus the truncation note",
              mediumLines.count == 401 && mediumLines.last == "… [diff truncated at 400 lines / 65536 bytes]",
              "lines \(mediumLines.count) last \(mediumLines.last ?? "")")
        check("D4c identical text gives no diff; a new file gives an all-added diff",
              DiffUtil.unifiedDiff(old: "same\n", new: "same\n", path: "/s") == nil
              && (DiffUtil.unifiedDiff(old: "", new: "x\n", path: "/n")?.hasSuffix("@@ -0,0 +1 @@\n+x\n") ?? false),
              DiffUtil.unifiedDiff(old: "", new: "x\n", path: "/n") ?? "nil")
    }

    // MARK: - D5: a >1 MB rewrite

    static func megabyteRewrite(_ check: Check, dir: URL) async {
        let path = dir.appendingPathComponent("big.html").path
        let old = htmlFile(lines: 20_000, variant: "m1"), new = htmlFile(lines: 20_000, variant: "m2")
        try? old.write(toFile: path, atomically: true, encoding: .utf8)
        await FileTimeTracker.shared.recordRead(path: path)
        let run = await bounded(callBound) { await FilesystemTools.shared.writeFile(path: path, content: new).content }
        check("D5a >1 MB write_file rewrite returns (\(old.utf8.count) bytes, \(String(format: "%.2f", run.elapsed)) s)",
              old.utf8.count > 1_000_000 && run.value != nil && run.elapsed < promptBound, "hung or slow: \(run.elapsed) s")
        let result = json(run.value ?? "")
        let (ok, detail) = cappedDiffOK(result["diff"] as? String, path: path)
        check("D5b result: success and a correctly capped diff", result["success"] as? Bool == true && ok, detail)
    }

    // MARK: - D6-D8: stand-in diff binaries

    static func script(_ dir: URL, _ name: String, _ body: String) -> String {
        let url = dir.appendingPathComponent(name)
        try? ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, 0o755)
        return url.path
    }

    static func deadlineBackstop(_ check: Check, dir: URL) async {
        let stuck = script(dir, "stuck-diff", "exec sleep 30")
        let run = await bounded(callBound) {
            DiffUtil.unifiedDiff(old: "a\n", new: "b\n", path: "/x", timeout: 0.5, executable: stuck) ?? "<nil>"
        }
        check("D6a a diff that never finishes: nil after the deadline (\(String(format: "%.2f", run.elapsed)) s)",
              run.value == "<nil>" && run.elapsed < 5, "value \(run.value ?? "hung") elapsed \(run.elapsed)")
        check("D6b the stuck diff was killed and reaped", childPids(named: ["sleep", "stuck-diff"]).isEmpty,
              "\(childPids(named: ["sleep", "stuck-diff"]))")
    }

    static func stderrFlood(_ check: Check, dir: URL) async {
        let noisy = script(dir, "noisy-diff",
                           "head -c 1048576 /dev/zero 1>&2\nprintf -- '--- %s\\n+++ %s\\n@@ -1 +1 @@\\n-a\\n+b\\n' \"$4\" \"$5\"\nexit 1")
        let run = await bounded(callBound) {
            DiffUtil.unifiedDiff(old: "a\n", new: "b\n", path: "/x", executable: noisy) ?? "<nil>"
        }
        check("D7 1 MB on stderr cannot block diff; stdout still captured (\(String(format: "%.2f", run.elapsed)) s)",
              run.value == "--- a//x\n+++ b//x\n@@ -1 +1 @@\n-a\n+b\n" && run.elapsed < promptBound, run.value ?? "hung")
    }

    static func troubleExit(_ check: Check, dir: URL) async {
        let trouble = script(dir, "trouble-diff", "head -c 204800 /dev/zero | tr '\\0' 'x'\nexit 2")
        let run = await bounded(callBound) {
            DiffUtil.unifiedDiff(old: "a\n", new: "b\n", path: "/x", executable: trouble) ?? "<nil>"
        }
        check("D8 exit 2 with 200 KB of output: nil, promptly (\(String(format: "%.2f", run.elapsed)) s)",
              run.value == "<nil>" && run.elapsed < promptBound, run.value.map { String($0.prefix(80)) } ?? "hung")
    }

    // MARK: - D9-D10: markers and leftovers

    static func stageMarkerPairs(_ check: Check) {
        _ = StageMarkers.flush(timeout: 10)
        guard let data = try? Data(contentsOf: StageMarkers.logURL) else {
            check("D9 fs.diff stage markers recorded", false, "no log at \(StageMarkers.logURL.path)"); return
        }
        var enters = 0, exits = 0
        for line in StageMarkersReader.splitLines(data).lines {
            guard let d = line.data(using: .utf8),
                  let r = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  r["stage"] as? String == "fs.diff" else { continue }
            if r["ev"] as? String == "enter" { enters += 1 }
            if r["ev"] as? String == "exit" { exits += 1 }
        }
        check("D9 every fs.diff enter has its exit (write_file, edit_file and apply_patch calls)", enters >= 5 && enters == exits,
              "enter \(enters) exit \(exits)")
    }

    static func leftovers(_ check: Check, tempBefore: Set<String>) {
        let pids = childPids(named: ["diff"])
        check("D10a no diff child process left running", pids.isEmpty, "\(pids)")
        let extra = diffTempFiles().subtracting(tempBefore)
        check("D10b no ada-diff-* temp file left behind", extra.isEmpty, "\(extra.sorted())")
    }

    static func diffTempFiles() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []
        return Set(names.filter { $0.hasPrefix("ada-diff-") })
    }

    /// Live direct children of this process whose command basename is in `names`.
    static func childPids(named names: Set<String>) -> [Int32] {
        let me = getpid()
        #if os(Linux)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/proc")) ?? []
        return entries.compactMap { Int32($0) }.filter { pid in
            guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
                  let open = stat.firstIndex(of: "("), let close = stat.lastIndex(of: ")") else { return false }
            let comm = String(stat[stat.index(after: open)..<close])
            let rest = stat[stat.index(after: close)...].split(separator: " ")
            guard rest.count > 1, rest[0] != "Z", Int32(rest[1]) == me else { return false }
            return names.contains(comm)
        }
        #else
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-A", "-o", "pid=,ppid=,stat=,comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile() // read to EOF before waiting
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { row in
            let f = row.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard f.count == 4, let pid = Int32(f[0]), Int32(f[1]) == me, !f[2].hasPrefix("Z"),
                  names.contains((String(f[3]) as NSString).lastPathComponent) else { return nil }
            return pid
        }
        #endif
    }
}
