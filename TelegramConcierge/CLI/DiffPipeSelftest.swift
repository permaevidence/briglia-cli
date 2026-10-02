import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Diff pipe deadlock (field incident on v0.2.45, 2026-10-01): `DiffUtil`
/// waited for `/usr/bin/diff` to exit BEFORE reading its stdout pipe and never
/// read its stderr pipe. A diff larger than the pipe buffer (~64 KB) blocked
/// diff in write() and Briglia in waitUntilExit(), forever, inside the
/// FilesystemTools actor — the stage-marker log showed `fs.diff` enter, then
/// only `stall_suspected`.
///
/// Drives the REAL write_file / edit_file / apply_patch paths with full
/// rewrites of an ~80 KB / 1,400-line file and a >1 MB file, checks small
/// diffs and the caps are unchanged, the backstop deadline (killed + reaped,
/// nil result), a stderr flood, and that no diff child process and no
/// ada-diff-* temp file is left behind. Every tool call runs under its own
/// watchdog, so the OLD code fails the rows instead of hanging the suite.
///
/// Isolation: re-executes itself in a private scratch home (HOME,
/// XDG_*_HOME, CFFIXED_USER_HOME, TMPDIR) under a differently named hard link
/// with a reserved test prefix, so it never touches a real install's state or
/// preference domain.
struct DiffPipeSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__diff-pipe-selftest",
        abstract: "Internal: verify the file-tool diff never deadlocks on large output.",
        shouldDisplay: false
    )

    @Flag(name: .long, help: .hidden) var child = false

    static let linkName = "briglia-mw-diffpipe-selftest"
    static let rootPrefix = "briglia-diff-pipe-"
    /// Generous per-call bound; the fixed code returns in well under a second.
    static let callBound: TimeInterval = 30
    /// What "returns promptly" means: far below the 10 s backstop deadline,
    /// so a diff that only finishes because the deadline killed a blocked
    /// reader can never pass.
    static let promptBound: TimeInterval = 5

    func run() async throws {
        guard adaCLIVersion.hasSuffix("-dev") else {
            print("✖ development build required"); throw ExitCode(1)
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        guard child else { try Self.reexecIsolated(); return }
        let failures = await Self.battery()
        // A failed run may have left a blocked diff behind (old code): kill it
        // so the suite exits; the leftover row has already recorded it.
        for pid in Self.childPids(named: ["diff", "sleep", "sh"]) { kill(pid, SIGKILL) }
        if failures > 0 { throw ExitCode(1) }
    }

    static func reexecIsolated() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(rootPrefix + UUID().uuidString)
        for sub in ["home", "home/.config", "home/.local/share", "tmp"] {
            try fm.createDirectory(at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: root) }
        let home = root.appendingPathComponent("home").path
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key.hasPrefix("BRIGLIA_") || key.hasPrefix("ADA_") { env.removeValue(forKey: key) }
        env["HOME"] = home
        env["CFFIXED_USER_HOME"] = home
        env["XDG_CONFIG_HOME"] = home + "/.config"
        env["XDG_DATA_HOME"] = home + "/.local/share"
        env["XDG_STATE_HOME"] = home + "/.local/state"
        env["XDG_CACHE_HOME"] = home + "/.cache"
        env["TMPDIR"] = root.appendingPathComponent("tmp").path + "/"
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).resolvingSymlinksInPath()
        let linked = root.appendingPathComponent(linkName)
        if link(source.path, linked.path) != 0 { try fm.copyItem(at: source, to: linked) }
        let process = Process()
        process.executableURL = linked
        process.arguments = ["__diff-pipe-selftest", "--child"]
        process.environment = env
        try process.run()
        process.waitUntilExit()
        // The file tools write no preferences; purge (and wait for the
        // cfprefsd shell) only if the throwaway domain was created after all.
        if TestPrefsDomains.candidatePaths(linkName).contains(where: { fm.fileExists(atPath: $0) }) {
            TestPrefsDomains.purge(linkName)
            TestPrefsDomains.finalSweep()
        }
        if process.terminationStatus != 0 { throw ExitCode(process.terminationStatus) }
    }

    typealias Check = (String, Bool, String) -> Void

    static func battery() async -> Int {
        var total = 0, failures = 0
        let check: Check = { label, ok, detail in
            total += 1
            if !ok { failures += 1 }
            print("\(ok ? "✔" : "✖") \(label)\(ok || detail.isEmpty ? "" : " — \(String(detail.prefix(600)))")")
        }
        // Inside the scratch home (removed by the parent); macOS Foundation
        // ignores TMPDIR, so temporaryDirectory is the shared user temp dir.
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSTemporaryDirectory()
        let work = URL(fileURLWithPath: home).appendingPathComponent("work-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let tempBefore = diffTempFiles()
        await writeFileRewrite(check, dir: work)
        await editFileRewrite(check, dir: work)
        await applyPatchRewrite(check, dir: work)
        await smallDiffUnchanged(check, dir: work)
        await megabyteRewrite(check, dir: work)
        await deadlineBackstop(check, dir: work)
        await stderrFlood(check, dir: work)
        await troubleExit(check, dir: work)
        stageMarkerPairs(check)
        leftovers(check, tempBefore: tempBefore)
        print("Diff pipe selftest: \(total - failures)/\(total) passed")
        return failures
    }

    // MARK: - Helpers

    /// Runs `op` under a watchdog; nil when it did not finish within `seconds`.
    static func bounded<T: Sendable>(_ seconds: TimeInterval,
                                     _ op: @escaping @Sendable () async -> T) async -> (value: T?, elapsed: TimeInterval) {
        let start = Date()
        let value: T? = await withCheckedContinuation { continuation in
            let once = Once(continuation)
            Task.detached { once.resume(await op()) }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { once.resume(nil) }
        }
        return (value, Date().timeIntervalSince(start))
    }

    final class Once<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T?, Never>?
        init(_ continuation: CheckedContinuation<T?, Never>) { self.continuation = continuation }
        func resume(_ value: T?) {
            lock.lock(); let c = continuation; continuation = nil; lock.unlock()
            c?.resume(returning: value)
        }
    }

    /// HTML-ish file of `lines` lines (~58 bytes each); `variant` changes every line.
    static func htmlFile(lines: Int, variant: String) -> String {
        var out = ""
        out.reserveCapacity(lines * 64)
        for i in 0..<lines {
            out += "<div class=\"row-\(i)\" data-v=\"\(variant)\"><span>cell \(i) \(variant)</span></div>\n"
        }
        return out
    }

    static func json(_ content: String) -> [String: Any] {
        guard let data = content.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    /// The capped-diff contract: real headers, truncation note, within caps.
    static func cappedDiffOK(_ diff: String?, path: String) -> (Bool, String) {
        guard let diff else { return (false, "no diff in the result") }
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false)
        let ok = diff.hasPrefix("--- a/" + path) && diff.contains("\n+++ b/" + path)
            && diff.contains("… [diff truncated at 400 lines / 65536 bytes]")
            && lines.count <= 401 && diff.utf8.count <= 64 * 1024 + 64
        return (ok, "lines \(lines.count) bytes \(diff.utf8.count) head \(diff.prefix(120))")
    }

    // MARK: - D1-D3: full rewrites through the three real tool paths

    static func writeFileRewrite(_ check: Check, dir: URL) async {
        let path = dir.appendingPathComponent("page.html").path
        let old = htmlFile(lines: 1_400, variant: "old"), new = htmlFile(lines: 1_400, variant: "new")
        try? old.write(toFile: path, atomically: true, encoding: .utf8)
        check("D1a fixture: ~80 KB / 1,400 lines, full-rewrite diff far above one pipe buffer",
              old.utf8.count > 75_000 && old.utf8.count + new.utf8.count > 2 * 65_536, "\(old.utf8.count) bytes")
        await FileTimeTracker.shared.recordRead(path: path)
        let run = await bounded(callBound) { await FilesystemTools.shared.writeFile(path: path, content: new).content }
        check("D1b write_file full rewrite returns (\(String(format: "%.2f", run.elapsed)) s)", run.value != nil && run.elapsed < promptBound, "hung or slow: \(run.elapsed) s")
        let result = json(run.value ?? "")
        let (ok, detail) = cappedDiffOK(result["diff"] as? String, path: path)
        check("D1c write_file result: success and a correctly capped diff", result["success"] as? Bool == true && ok, detail)
        check("D1d file on disk is the new content", (try? String(contentsOfFile: path, encoding: .utf8)) == new, "")
    }

    static func editFileRewrite(_ check: Check, dir: URL) async {
        let path = dir.appendingPathComponent("edit.html").path
        let old = htmlFile(lines: 1_400, variant: "e1"), new = htmlFile(lines: 1_400, variant: "e2")
        try? old.write(toFile: path, atomically: true, encoding: .utf8)
        await FileTimeTracker.shared.recordRead(path: path)
        let run = await bounded(callBound) {
            await FilesystemTools.shared.editFile(path: path, oldString: old, newString: new).content
        }
        check("D2a edit_file full rewrite returns (\(String(format: "%.2f", run.elapsed)) s)", run.value != nil && run.elapsed < promptBound, "hung or slow: \(run.elapsed) s")
        let result = json(run.value ?? "")
        let (ok, detail) = cappedDiffOK(result["diff"] as? String, path: path)
        check("D2b edit_file result: success and a correctly capped diff", result["success"] as? Bool == true && ok,
              detail + " " + String((run.value ?? "").prefix(200)))
    }

    static func applyPatchRewrite(_ check: Check, dir: URL) async {
        let path = dir.appendingPathComponent("patch.html").path
        let old = htmlFile(lines: 1_400, variant: "p1"), new = htmlFile(lines: 1_400, variant: "p2")
        try? old.write(toFile: path, atomically: true, encoding: .utf8)
        await FileTimeTracker.shared.recordRead(path: path)
        var patch = "*** Begin Patch\n*** Update File: \(path)\n@@\n"
        for line in old.split(separator: "\n") { patch += "-\(line)\n" }
        for line in new.split(separator: "\n") { patch += "+\(line)\n" }
        patch += "*** End Patch"
        let text = patch
        let run = await bounded(callBound) { await ApplyPatch.run(patchText: text).content }
        check("D3a apply_patch full rewrite returns (\(String(format: "%.2f", run.elapsed)) s)", run.value != nil && run.elapsed < promptBound, "hung or slow: \(run.elapsed) s")
        let result = json(run.value ?? "")
        let diff = (result["diffs_by_file"] as? [String: Any])?[path] as? String
        let (ok, detail) = cappedDiffOK(diff, path: path)
        check("D3b apply_patch result: success and a correctly capped per-file diff", result["success"] as? Bool == true && ok,
              detail + " " + String((run.value ?? "").prefix(200)))
        check("D3c file on disk is the new content", (try? String(contentsOfFile: path, encoding: .utf8)) == new, "")
    }
}
