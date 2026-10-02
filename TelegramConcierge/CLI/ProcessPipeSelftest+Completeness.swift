import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Codex round-1 findings on 9e3319e, as permanent rows:
/// - R1: Shortcuts returned a cut 64 MB prefix as plain success, and a cut
///   inside a multi-byte character decoded the whole text as "".
/// - R2: when a descendant kept the pipe open, the helper returned but its
///   reader threads (and buffers) stayed alive until the descendant exited.
/// - Completeness: a capture that did not reach EOF was used as complete.
extension ProcessPipeSelftest {

    // MARK: - Fixtures

    /// Writes a fixture file directly (fast and deterministic, unlike
    /// generating 70 MB through `head | tr` on a busy machine) and returns a
    /// stand-in that cats it.
    static func catScript(_ dir: URL, _ name: String, _ data: Data) -> String {
        let file = dir.appendingPathComponent(name + ".bin")
        try? data.write(to: file)
        return script(dir, name, "exec cat '\(file.path)'")
    }

    static let overCap = 70 * megabyte

    /// A stand-in that prints `body` (shell) then leaves a background
    /// `sleep 60` holding its stdout AND stderr, records the sleeper's pid in
    /// `pidFile`, and exits 0.
    static func holderScript(_ dir: URL, _ name: String, body: String, pidFile: String) -> String {
        script(dir, name, "\(body)\n(exec sleep 60) &\necho $! > '\(pidFile)'\nexit 0")
    }

    static func readPid(_ path: String, wait: TimeInterval = 5) -> Int32? {
        let deadline = Date().addingTimeInterval(wait)
        repeat {
            if let text = try? String(contentsOfFile: path, encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return pid }
            usleep(20_000)
        } while Date() < deadline
        return nil
    }

    static func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    // MARK: - L1-L3: bounded capture memory (fixture via cat: fast)

    static func captureLimits(_ check: Check, dir: URL) async {
        let big = script(dir, "cap-1mb", flood(megabyte, "c"))
        let capped = await bounded { () -> String in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: big)
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return "launch failed" }
            let capture = ProcessOutputCapture(stdout: out, stderr: nil, limit: 100_000)
            capture.start()
            let exited = ProcessOutputCapture.waitForExit(p, until: Date().addingTimeInterval(10))
            let o = capture.finish(within: 2)
            return "\(exited) \(o.stdout.count) \(o.stdoutTruncated) \(o.stdoutEnd == .eof) \(o.stdoutComplete) \(o.stdout == Data(repeating: UInt8(ascii: "c"), count: 100_000))"
        }
        check("L1 1 MB through a 100,000-byte limit: drained to EOF, prefix kept, flagged truncated and not complete (\(secs(capped.elapsed)) s)",
              capped.value == "true 100000 true true false true" && capped.elapsed < promptBound, capped.value ?? "hung")
        let huge = catScript(dir, "cap-70mb", Data(repeating: UInt8(ascii: "h"), count: overCap))
        let z = await zipRun(huge)
        check("L2 unzip output over 64 MB fails clearly instead of a cut listing (\(secs(z.elapsed)) s)",
              z.value == "ERR \(EFBIG):Failed to inspect ZIP archive. unzip output exceeded 64 MB." && z.elapsed < promptBound,
              String((z.value ?? "hung").prefix(120)))
        let g = await gwsRun(huge, timeout: 60)
        check("L3 gws output over 64 MB fails as \"output exceeded 64 MB\" (\(secs(g.elapsed)) s)",
              g.value?.stdout == nil && g.value?.failureDetail == "output exceeded 64 MB" && g.elapsed < promptBound,
              g.value?.failureDetail ?? "hung")
    }

    // MARK: - S6: Shortcuts never return a cut capture as output

    static func shortcutsCompleteness(_ check: Check, dir: URL) async {
        let ascii = catScript(dir, "sc-70mb", Data(repeating: UInt8(ascii: "q"), count: overCap))
        let r1 = await shortcutRun(ascii, timeout: 60)
        check("S6a 70 MB from a shortcut: no 64 MB prefix, outputProblem \"output exceeded 64 MB\" (\(secs(r1.elapsed)) s)",
              r1.value?.exitCode == 0 && r1.value?.stdoutData.isEmpty == true
              && r1.value?.outputProblem == "output exceeded 64 MB" && r1.elapsed < promptBound,
              "exit \(r1.value?.exitCode ?? -99) \(r1.value?.stdoutData.count ?? -1) bytes, \(r1.value?.outputProblem ?? "no problem")")

        // Codex's UTF-8 case: 64 MiB - 1 ASCII bytes then "é", so a 64 MiB cut
        // lands inside the character.
        var split = Data(repeating: UInt8(ascii: "a"), count: ProcessOutputCapture.defaultLimit - 1)
        split.append(contentsOf: Array("é".utf8))
        let r2 = await shortcutRun(catScript(dir, "sc-utf8", split), timeout: 60)
        check("S6b a cap that would split \"é\": reported as incomplete, never decoded to \"\" as success",
              r2.value?.stdoutData.isEmpty == true && r2.value?.outputProblem == "output exceeded 64 MB",
              "\(r2.value?.stdoutData.count ?? -1) bytes, \(r2.value?.outputProblem ?? "no problem")")

        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        png.append(Data(repeating: 0x42, count: overCap))
        let r3 = await shortcutRun(catScript(dir, "sc-png", png), timeout: 60)
        var saved = 0
        let built = r3.value.map { r in
            ToolExecutor.buildShortcutResult(
                shortcutName: "Big Image", exitCode: r.exitCode, finalOutputData: r.stdoutData,
                outputProblem: r.outputProblem, appleEventsPermissionDenied: false, appleScriptErrorText: "",
                saveImage: { data, name, mime in saved += 1; return FileAttachment(data: data, mimeType: mime, filename: name, sourcePath: nil) })
        }
        let json = built.flatMap { try? JSONSerialization.jsonObject(with: Data($0.content.utf8)) as? [String: Any] } ?? [:]
        check("S6c a 70 MB image is not saved or attached; the tool result is a failure with error_code output_incomplete",
              r3.value?.stdoutData.isEmpty == true && saved == 0 && built?.attachment == nil
              && json["success"] as? Bool == false && json["error_code"] as? String == "output_incomplete"
              && (json["message"] as? String) == "Shortcut 'Big Image' ran, but its output exceeded 64 MB; no output was returned."
              && json["output"] == nil && json["output_file"] == nil,
              built?.content ?? "no result")

        // The result builder also refuses data passed alongside a problem.
        let forced = ToolExecutor.buildShortcutResult(
            shortcutName: "X", exitCode: 0, finalOutputData: png.prefix(1_000), outputProblem: "output exceeded 64 MB",
            appleEventsPermissionDenied: false, appleScriptErrorText: "",
            saveImage: { data, name, mime in saved += 1; return FileAttachment(data: data, mimeType: mime, filename: name, sourcePath: nil) })
        check("S6d with outputProblem set the builder ignores any bytes: nothing saved, no output field",
              saved == 0 && forced.attachment == nil && !forced.content.contains("\"output\"") && forced.content.contains("output_incomplete"),
              forced.content)

        // Complete output that is not valid UTF-8 (cut sequence at the end):
        // the text survives with U+FFFD instead of becoming "".
        var bad = Data("hello shortcut".utf8)
        bad.append(0xC3)
        let text = ToolExecutor.buildShortcutResult(
            shortcutName: "T", exitCode: 0, finalOutputData: bad, outputProblem: nil,
            appleEventsPermissionDenied: false, appleScriptErrorText: "", saveImage: { _, _, _ in nil })
        let textJSON = (try? JSONSerialization.jsonObject(with: Data(text.content.utf8)) as? [String: Any]) ?? [:]
        check("S6e non-UTF-8 complete output is never decoded to empty text",
              (textJSON["output"] as? String)?.hasPrefix("hello shortcut") == true && textJSON["success"] as? Bool == true,
              text.content)

        // Unchanged paths: complete text and complete image.
        let ok = ToolExecutor.buildShortcutResult(
            shortcutName: "T", exitCode: 0, finalOutputData: Data("line1\nline2\n".utf8), outputProblem: nil,
            appleEventsPermissionDenied: false, appleScriptErrorText: "", saveImage: { _, _, _ in nil })
        check("S6f complete text result unchanged",
              ok.content == "{\"success\": true, \"exit_code\": 0, \"shortcut\": \"T\", \"output\": \"line1\\nline2\", \"message\": \"Shortcut 'T' executed successfully\"}",
              ok.content)
        var smallPng = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]); smallPng.append(Data(repeating: 1, count: 100))
        let img = ToolExecutor.buildShortcutResult(
            shortcutName: "I", exitCode: 0, finalOutputData: smallPng, outputProblem: nil,
            appleEventsPermissionDenied: false, appleScriptErrorText: "",
            saveImage: { data, name, mime in saved += 1; return FileAttachment(data: data, mimeType: mime, filename: name, sourcePath: nil) })
        check("S6g complete image still saved once and attached as image/png",
              saved == 1 && img.attachment?.mimeType == "image/png" && img.attachment?.data == smallPng && img.content.contains("\"success\": true"),
              img.content)
        for name in ["sc-70mb", "sc-utf8", "sc-png", "cap-70mb"] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name + ".bin"))
        }
    }

    // MARK: - R1-R3: reader lifetime and completeness when a descendant holds the pipe

    /// One raw capture of a child that prints 1 MB, then leaves a sleeper
    /// holding stdout + stderr. Returns the result and the sleeper pid.
    /// Does not wait for the child's exit (Linux corelibs exit detection can
    /// be held by the sleeper too); the pid file is written after the 1 MB.
    static func rawHeldCapture(_ dir: URL, index: Int) -> (out: ProcessOutputCapture.Output?, pid: Int32?, elapsed: TimeInterval) {
        let pidFile = dir.appendingPathComponent("raw-holder-\(index).pid").path
        let exe = holderScript(dir, "raw-holder-\(index)", body: flood(megabyte, "r"), pidFile: pidFile)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return (nil, nil, 0) }
        let capture = ProcessOutputCapture(stdout: out, stderr: err)
        capture.start()
        let pid = readPid(pidFile)
        let start = Date()
        let o = capture.finish(within: 0.5)
        return (o, pid, Date().timeIntervalSince(start))
    }

    static func readerLifetime(_ check: Check, dir: URL) async {
        let baseThreads = ProcessOutputCapture.liveReaderThreads
        let baseReaders = ProcessOutputCapture.bufferedBytes
        var pids: [Int32] = []
        var outcomes: [String] = []
        var slowest: TimeInterval = 0
        for i in 0..<4 {
            let r = rawHeldCapture(dir, index: i)
            if let pid = r.pid { pids.append(pid) }
            slowest = max(slowest, r.elapsed)
            if let o = r.out {
                outcomes.append("\(o.stdout.count == megabyte) \(o.stdoutEnd == .stillOpen) \(o.stderrEnd == .stillOpen) \(o.stdoutComplete)")
            }
        }
        // Each capture went out of scope inside rawHeldCapture.
        let threads = ProcessOutputCapture.liveReaderThreads - baseThreads
        let readers = ProcessOutputCapture.bufferedBytes - baseReaders
        let holdersAlive = pids.count == 4 && pids.allSatisfy(alive)
        check("R1a 4 captures held open by a descendant each return within the grace + one poll (slowest \(secs(slowest)) s)",
              outcomes.count == 4 && slowest < 1.5, "\(outcomes.count) outcomes")
        check("R1b each reports its 1 MB with stdout/stderr \"still open\", not complete",
              outcomes.allSatisfy { $0 == "true true true false" }, "\(outcomes)")
        check("R1c no reader thread running and no captured bytes held by readers while all 4 descendants are still alive",
              threads == 0 && readers == 0 && holdersAlive,
              "threads +\(threads), buffered +\(readers) bytes, holders alive \(holdersAlive) (\(pids.count) pids)")
        for pid in pids { kill(pid, SIGKILL) }

        let none = ProcessOutputCapture(stdout: Pipe(), stderr: nil).finish(within: 0.05)
        check("R1d finish before start reports \"not captured\", never complete",
              none.stdoutEnd == .notStarted && none.stdoutProblem == "was not captured", "\(none.stdoutEnd)")
        check("R1e a read error is reported as incomplete",
              ProcessOutputCapture.Output.problem(truncated: false, end: .readError(EIO)) == "could not be read completely (read error \(EIO))", "")
    }

    /// Through each production helper: the child prints "done" and exits,
    /// leaving a sleeper holding stdout + stderr. Each helper returns within
    /// its 2 s grace, reports the output as incomplete instead of using it,
    /// and leaves no reader behind while the sleeper is still alive.
    /// macOS only: on Linux corelibs the sleeper also holds Foundation's exit
    /// detection, so these helpers wait on their own exit polling instead.
    static func descendantHoldsPipe(_ check: Check, dir: URL) async {
        #if os(macOS)
        let baseThreads = ProcessOutputCapture.liveReaderThreads
        let baseReaders = ProcessOutputCapture.bufferedBytes
        var pids: [Int32] = []
        func holder(_ name: String) -> (String, String) {
            let pidFile = dir.appendingPathComponent(name + ".pid").path
            return (holderScript(dir, name, body: "printf 'done'", pidFile: pidFile), pidFile)
        }
        let (zExe, zPid) = holder("holder-zip")
        let z = await zipRun(zExe)
        if let p = readPid(zPid) { pids.append(p) }
        let (gExe, gPid) = holder("holder-gws")
        let g = await gwsRun(gExe)
        if let p = readPid(gPid) { pids.append(p) }
        let (sExe, sPid) = holder("holder-sc")
        let s = await shortcutRun(sExe)
        if let p = readPid(sPid) { pids.append(p) }
        let still = "was still open when the process ended (a background process kept it open); it may be incomplete"
        check("H1a a grandchild holding stdout cannot hang unzip / gws / shortcuts (\(secs(z.elapsed)) / \(secs(g.elapsed)) / \(secs(s.elapsed)) s)",
              max(z.elapsed, g.elapsed, s.elapsed) < promptBound, "")
        check("H1b unzip: an unfinished listing is refused, not used",
              z.value == "ERR \(EIO):Failed to inspect ZIP archive. unzip output \(still).", z.value ?? "hung")
        check("H1c gws: an unfinished capture is a failure, not stdout",
              g.value?.stdout == nil && g.value?.failureDetail == "output \(still)", g.value?.failureDetail ?? "hung")
        check("H1d shortcuts: exit 0 but outputProblem set and no bytes returned",
              s.value?.exitCode == 0 && s.value?.stdoutData.isEmpty == true && s.value?.outputProblem == "output \(still)",
              s.value?.outputProblem ?? "no problem")
        let threads = ProcessOutputCapture.liveReaderThreads - baseThreads
        let readers = ProcessOutputCapture.bufferedBytes - baseReaders
        let holdersAlive = pids.count == 3 && pids.allSatisfy(alive)
        check("H1e after the three helper calls no reader thread running and no captured bytes held by readers while the grandchildren still run",
              threads == 0 && readers == 0 && holdersAlive,
              "threads +\(threads), buffered +\(readers) bytes, holders alive \(holdersAlive)")
        for pid in pids { kill(pid, SIGKILL) }
        #endif
    }
}
