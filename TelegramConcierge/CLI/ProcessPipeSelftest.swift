import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Same pipe deadlock as the file-tool diff, in the three other helpers that
/// read a child's output only after it exits:
///
/// - `ProjectsZipAutoExtractor.runProcess` (`unzip -Z1` / extraction): a zip
///   of ~1,500+ entries hung the extractor queue forever (no timeout at all).
/// - `GoogleWorkspaceService.runBlockingProcess` / `runProcessAsync` (gws,
///   brew/pip toolchain installs, skills doctor): > 64 KB of output stalled
///   until the timeout and was reported as "timed out".
/// - `ToolExecutor.runShortcutProcess` (shortcuts CLI, its `| cat` fallback,
///   osascript): > 64 KB stalled until the 120 s timeout and failed.
///
/// Drives each helper with stand-in executables (and the real unzip on a
/// 3,000-entry zip): large stdout (~100 KB and ~1 MB) comes back complete,
/// a stderr flood cannot block, error strings and small outputs are
/// unchanged, timeouts still fire and reap, no child is left behind. Every
/// call runs under a watchdog so the OLD code fails rows instead of hanging.
///
/// Isolation: re-executes itself in a private scratch home under a hard link
/// with a reserved test prefix, like `__diff-pipe-selftest`.
struct ProcessPipeSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__process-pipe-selftest",
        abstract: "Internal: verify the unzip / gws / shortcuts helpers never deadlock on large output.",
        shouldDisplay: false
    )

    @Flag(name: .long, help: .hidden) var child = false

    static let linkName = "briglia-mw-procpipe-selftest"
    static let rootPrefix = "briglia-proc-pipe-"
    /// Watchdog per call; fixed code returns in well under a second.
    static let callBound: TimeInterval = 15
    /// "Returns promptly": far below every timeout the rows pass in.
    static let promptBound: TimeInterval = 5
    static let megabyte = 1_048_576
    static let childNames: Set<String> = ["sleep", "yes", "sh", "unzip", "head", "tr", "cat", "zip"]

    func run() async throws {
        guard adaCLIVersion.hasSuffix("-dev") else {
            print("✖ development build required"); throw ExitCode(1)
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        guard child else { try Self.reexecIsolated(); return }
        let failures = await Self.battery()
        // Old code leaves blocked children behind; the leftover row recorded
        // them already — kill them so the suite exits.
        for pid in DiffPipeSelftest.childPids(named: Self.childNames) { kill(pid, SIGKILL) }
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
        for key in env.keys where key.hasPrefix("BRIGLIA_") || key.hasPrefix("ADA_") || key.hasPrefix("SM_") {
            env.removeValue(forKey: key)
        }
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
        process.arguments = ["__process-pipe-selftest", "--child"]
        process.environment = env
        try process.run()
        process.waitUntilExit()
        if TestPrefsDomains.candidatePaths(linkName).contains(where: { fm.fileExists(atPath: $0) }) {
            TestPrefsDomains.purge(linkName)
            TestPrefsDomains.finalSweep()
        }
        if process.terminationStatus != 0 { throw ExitCode(process.terminationStatus) }
    }

    typealias Check = DiffPipeSelftest.Check

    static func battery() async -> Int {
        var total = 0, failures = 0
        let check: Check = { label, ok, detail in
            total += 1
            if !ok { failures += 1 }
            print("\(ok ? "✔" : "✖") \(label)\(ok || detail.isEmpty ? "" : " — \(String(detail.prefix(600)))")")
        }
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSTemporaryDirectory()
        let work = URL(fileURLWithPath: home).appendingPathComponent("work-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        await zipRealArchive(check, dir: work)
        await zipStandIns(check, dir: work)
        await zipErrorsAndTimeout(check, dir: work)
        await gwsLargeOutput(check, dir: work)
        await gwsErrorsAndTimeout(check, dir: work)
        await shortcutsLargeOutput(check, dir: work)
        await shortcutsErrorsAndTimeout(check, dir: work)
        await descendantHoldsPipe(check, dir: work)
        await captureLimits(check, dir: work)
        leftovers(check)
        print("Process pipe selftest: \(total - failures)/\(total) passed")
        return failures
    }

    // MARK: - Helpers

    static func script(_ dir: URL, _ name: String, _ body: String) -> String {
        DiffPipeSelftest.script(dir, name, body)
    }

    static func bounded<T: Sendable>(_ op: @escaping @Sendable () async -> T) async -> (value: T?, elapsed: TimeInterval) {
        await DiffPipeSelftest.bounded(callBound, op)
    }

    static func secs(_ t: TimeInterval) -> String { String(format: "%.2f", t) }

    /// Writes `n` bytes of `char` to stdout (or stderr with `toStderr`).
    static func flood(_ n: Int, _ char: String, toStderr: Bool = false) -> String {
        "head -c \(n) /dev/zero | tr '\\0' '\(char)'" + (toStderr ? " 1>&2" : "")
    }

    static func leftovers(_ check: Check) {
        // Give terminated children a moment to be reaped by Foundation.
        let deadline = Date().addingTimeInterval(3)
        var pids = DiffPipeSelftest.childPids(named: childNames)
        while !pids.isEmpty && Date() < deadline {
            usleep(50_000)
            pids = DiffPipeSelftest.childPids(named: childNames)
        }
        check("X1 no child process left running (unzip, sh, sleep, yes, …)", pids.isEmpty, "\(pids)")
    }

    // MARK: - Z1-Z2: real unzip on a 3,000-entry archive

    /// Builds a zip of 3,000 files whose `unzip -Z1` listing is ~216 KB.
    static func buildBigZip(_ dir: URL) -> (zip: URL, names: [String])? {
        let fm = FileManager.default
        let src = dir.appendingPathComponent("zip-src")
        var names: [String] = []
        for i in 0..<3_000 {
            let rel = String(format: "proj/node_modules/package-%04ld/lib/some-fairly-long-module-name-%04ld.js", i / 10, i)
            let url = src.appendingPathComponent(rel)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard (try? "module \(i)\n".write(to: url, atomically: false, encoding: .utf8)) != nil else { return nil }
            names.append(rel)
        }
        let zip = dir.appendingPathComponent("big.zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["zip", "-q", "-r", "-D", zip.path, "proj"]
        p.currentDirectoryURL = src
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        return p.terminationStatus == 0 ? (zip, names) : nil
    }

    static func zipRealArchive(_ check: Check, dir: URL) async {
        guard let (zip, names) = buildBigZip(dir) else {
            check("Z1 fixture: 3,000-entry zip built", false, "zip failed"); return
        }
        let listingBytes = names.reduce(0) { $0 + $1.utf8.count + 1 }
        check("Z1 fixture: 3,000-entry zip, -Z1 listing \(listingBytes) bytes (> 2 pipe buffers)",
              names.count == 3_000 && listingBytes > 2 * 65_536, "")
        let list = await bounded { (try? ProjectsZipAutoExtractor.listArchiveEntries(archiveURL: zip)) ?? [] }
        check("Z2a unzip -Z1 listing returns promptly (\(secs(list.elapsed)) s)",
              list.value != nil && list.elapsed < promptBound, "hung or slow")
        check("Z2b listing holds all 3,000 entries exactly",
              Set(list.value ?? []) == Set(names), "got \(list.value?.count ?? -1)")
        let dest = dir.appendingPathComponent("zip-dest")
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let extract = await bounded { () -> String in
            do { try ProjectsZipAutoExtractor.unzipArchive(archiveURL: zip, destinationURL: dest); return "ok" }
            catch { return error.localizedDescription }
        }
        check("Z2c extraction of all 3,000 entries returns (\(secs(extract.elapsed)) s)",
              extract.value == "ok" && extract.elapsed < promptBound * 2, extract.value ?? "hung")
        let extracted = names.filter { FileManager.default.fileExists(atPath: dest.appendingPathComponent($0).path) }
        let sample = (try? String(contentsOf: dest.appendingPathComponent(names[2_999]), encoding: .utf8)) ?? ""
        check("Z2d every entry extracted with its content", extracted.count == 3_000 && sample == "module 2999\n",
              "\(extracted.count) files, sample \(sample.debugDescription)")
    }
}
