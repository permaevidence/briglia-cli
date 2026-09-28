import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Stage-marker diagnostics (write_file stall investigation, 2026-09-28):
/// record format and pairing through the REAL ToolExecutor write_file path
/// (git checkpoint included), no content leakage, owner-only modes, error and
/// cancellation outcomes, recreation after /deleteuserdata, crash durability
/// under SIGKILL, the stall REPORTER (one record, stage untouched), the
/// disabled switch, rotation, a hung log volume that must not slow the tool
/// path, and the Git reader barrier made visible by the markers.
///
/// Isolated: XDG_CONFIG_HOME/XDG_DATA_HOME under a temp root; child
/// processes get an explicit BRIGLIA_STAGE_MARKERS_PATH. Run it from a binary
/// NOT named `briglia` on macOS (the preference domain follows the name).
struct StageMarkersSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__stage-markers-selftest",
        abstract: "Internal: verify the tool stage-marker diagnostics.",
        shouldDisplay: false
    )

    @Option(name: .customLong("child"), help: "Internal child mode.")
    var child: String?

    @Option(name: .customLong("bench"), help: "Measure write_file latency with markers on/off (N calls per run).")
    var bench: Int?

    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        if let child {
            try await Self.runChild(child)
            return
        }
        guard adaCLIVersion.hasSuffix("-dev") else { throw ValidationError("Needs a development build") }
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("briglia-stage-markers-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        setenv("XDG_DATA_HOME", tempRoot.appendingPathComponent("data").path, 1)
        setenv("XDG_CONFIG_HOME", tempRoot.appendingPathComponent("config").path, 1)
        // The parent measures the default location and default threshold.
        unsetenv("BRIGLIA_STAGE_MARKERS")
        unsetenv("BRIGLIA_STAGE_MARKERS_PATH")
        unsetenv("BRIGLIA_STAGE_MARKERS_STDERR")
        unsetenv("BRIGLIA_STALL_REPORT_SECONDS")
        unsetenv("BRIGLIA_STAGE_MARKERS_MAX_BYTES")

        if let bench {
            try Self.runBench(count: bench, root: tempRoot)
            return
        }

        var total = 0, failures = 0
        func check(_ name: String, _ value: Bool, _ detail: String = "") {
            total += 1
            if !value { failures += 1 }
            print("\(value ? "✔" : "✖") \(name)\(value || detail.isEmpty ? "" : " — \(String(detail.prefix(600)))")")
        }
        try await Self.realWriteFile(check, root: tempRoot)
        try await Self.outcomes(check, root: tempRoot)
        Self.overhead(check)
        try Self.childRows(check, root: tempRoot)
        try Self.gitReaderBarrier(check, root: tempRoot)
        try Self.customPathRows(check, root: tempRoot)
        try Self.writeFailureRows(check, root: tempRoot)
        try Self.stallReportRows(check, root: tempRoot)
        print("Stage markers selftest: \(total - failures)/\(total) passed")
        if failures > 0 { throw ExitCode.failure }
    }

    typealias Check = (String, Bool, String) -> Void

    // MARK: - Helpers

    static func records(_ url: URL) -> [[String: Any]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
    }

    static func mode(_ path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    @discardableResult
    static func shell(_ command: String, in dir: String) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    static var selfPath: String {
        let arg0 = CommandLine.arguments[0]
        if arg0.hasPrefix("/") { return arg0 }
        return FileManager.default.currentDirectoryPath + "/" + arg0
    }

    struct ChildRun {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    /// Runs a child mode with extra environment; kills it after `timeout`.
    static func runChildProcess(_ mode: String, env extra: [String: String], timeout: TimeInterval) throws -> ChildRun {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: selfPath)
        p.arguments = ["__stage-markers-selftest", "--child", mode]
        var env = ProcessInfo.processInfo.environment
        for (k, v) in extra { env[k] = v }
        p.environment = env
        let outFile = FileManager.default.temporaryDirectory.appendingPathComponent("sm-out-\(UUID().uuidString)")
        let errFile = FileManager.default.temporaryDirectory.appendingPathComponent("sm-err-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: outFile.path, contents: nil)
        FileManager.default.createFile(atPath: errFile.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: outFile)
            try? FileManager.default.removeItem(at: errFile)
        }
        p.standardOutput = try FileHandle(forWritingTo: outFile)
        p.standardError = try FileHandle(forWritingTo: errFile)
        try p.run()
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while p.isRunning {
            if Date() > deadline {
                timedOut = true
                kill(p.processIdentifier, SIGKILL)
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        p.waitUntilExit()
        return ChildRun(status: p.terminationStatus,
                        stdout: (try? String(contentsOf: outFile, encoding: .utf8)) ?? "",
                        stderr: (try? String(contentsOf: errFile, encoding: .utf8)) ?? "",
                        timedOut: timedOut)
    }

    static func writeFileCall(path: String, content: String) -> ToolCall {
        let args = try! JSONSerialization.data(withJSONObject: ["path": path, "content": content])
        return ToolCall(id: "call_sm_\(UUID().uuidString.prefix(8))", type: "function",
                        function: FunctionCall(name: "write_file", arguments: String(data: args, encoding: .utf8)!))
    }

    // MARK: - SM1: the real write_file path

    static func realWriteFile(_ check: Check, root: URL) async throws {
        let repo = root.appendingPathComponent("work/sm-secret-dir")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        shell("git init -q . && printf 'one\\n' > tracked.txt && git add tracked.txt && git -c user.name=t -c user.email=t@example.invalid commit -q -m init && printf 'two\\n' > tracked.txt", in: repo.path)
        let target = repo.appendingPathComponent("notes.txt").path
        let secret = "SM-CONTENT-7f3a-do-not-log"
        let call = writeFileCall(path: target, content: secret + "\n")
        let executor = ToolExecutor()
        let results = try await StageMarkers.$round.withValue(7) {
            try await executor.executeParallel([call])
        }
        StageMarkers.event("selftest.after_round", call: nil)
        check("SM1a flush completes", StageMarkers.flush(timeout: 10), "")
        let log = StageMarkers.logURL
        check("SM1b default log path is <data>/logs/stage-markers.log",
              log.path == root.appendingPathComponent("data/briglia/logs/stage-markers.log").path, log.path)
        check("SM1c behaviour unchanged: write_file succeeded and wrote the content",
              results.first?.content.contains("\"success\":true") == true
              && (try? String(contentsOfFile: target, encoding: .utf8)) == secret + "\n",
              results.first?.content ?? "no result")
        check("SM1d the git checkpoint still rides on the result",
              results.first?.content.contains(GitCheckpointTracker.markerPrefix) == true, results.first?.content ?? "")

        let recs = records(log)
        let mine = recs.filter { ($0["call"] as? String) == call.id }
        let stages = Set(mine.map { $0["stage"] as? String ?? "" })
        let expected = ["executor.actor_acquire", "tool.execute", "git.checkpoint", "git.repo_root", "git.snapshot",
                        "git.run", "git.launch", "git.wait_exit", "git.reader_read_to_eof", "git.drain_stdout_barrier",
                        "git.ledger_append", "tool.body", "fs.write_file", "fs.inside_actor", "fs.exists_check",
                        "fs.ensure_parent_dir", "fs.write", "fs.write.atomic_temp_and_rename", "fs.read_ledger_record",
                        "fs.files_ledger_record", "fs.diff", "lsp.diagnostics", "fs.result_json",
                        "project_instructions.load", "project_instructions.verification", "result.build",
                        "round.tool_finished"]
        let missing = expected.filter { !stages.contains($0) }
        check("SM1e every expected stage is recorded for the call", missing.isEmpty, "missing \(missing)")

        var openIds: [Int: String] = [:]
        for r in mine {
            guard let id = r["id"] as? Int else { continue }
            if r["ev"] as? String == "enter" { openIds[id] = r["stage"] as? String }
            if r["ev"] as? String == "exit" { openIds.removeValue(forKey: id) }
        }
        check("SM1f every enter has a matching exit", openIds.isEmpty, "unclosed \(openIds)")

        let toolEnter = mine.first { $0["stage"] as? String == "tool.execute" && $0["ev"] as? String == "enter" }
        check("SM1g records carry tool name, depth and the round", toolEnter?["tool"] as? String == "write_file"
              && toolEnter?["depth"] as? Int == 0 && toolEnter?["round"] as? Int == 7, "\(toolEnter ?? [:])")
        let toolExit = mine.first { $0["stage"] as? String == "tool.execute" && $0["ev"] as? String == "exit" }
        check("SM1h exit has outcome, elapsed_ms, wall and monotonic time",
              toolExit?["outcome"] as? String == "ok" && toolExit?["elapsed_ms"] is Double
              && (toolExit?["t"] as? String)?.contains("T") == true && toolExit?["mono_ms"] is Double,
              "\(toolExit ?? [:])")

        func seq(_ stage: String, _ ev: String) -> Int {
            mine.first { $0["stage"] as? String == stage && $0["ev"] as? String == ev }?["seq"] as? Int ?? -1
        }
        check("SM1i order: actor acquired → checkpoint done → body → file write → body done",
              seq("executor.actor_acquire", "exit") < seq("git.checkpoint", "enter")
              && seq("git.drain_stdout_barrier", "exit") < seq("git.checkpoint", "exit")
              && seq("git.checkpoint", "exit") < seq("tool.body", "enter")
              && seq("tool.body", "enter") < seq("fs.write", "enter")
              && seq("fs.write", "exit") < seq("tool.body", "exit")
              && seq("tool.body", "exit") < seq("tool.execute", "exit"),
              "seqs")
        let roundEvents = recs.filter { ($0["stage"] as? String)?.hasPrefix("round.") == true }.map { $0["stage"] as? String ?? "" }
        check("SM1j round-level markers: dispatched, tool finished, all finished",
              roundEvents.contains("round.dispatched") && roundEvents.contains("round.tool_finished")
              && roundEvents.contains("round.all_tools_finished"), "\(roundEvents)")

        let raw = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        check("SM1k no file content and no full paths in the log (basenames only)",
              !raw.contains(secret) && !raw.contains(repo.path) && !raw.contains("work/sm-secret-dir")
              && raw.contains("notes.txt"),
              "content=\(raw.contains(secret)) fullpath=\(raw.contains(repo.path)) basename=\(raw.contains("notes.txt"))")
        check("SM1l log is 0600 in a 0700 logs directory",
              mode(log.path) == 0o600 && mode(log.deletingLastPathComponent().path) == 0o700,
              "file \(String(mode(log.path), radix: 8)) dir \(String(mode(log.deletingLastPathComponent().path), radix: 8))")
    }

    // MARK: - SM2/SM3/SM4: outcomes and /deleteuserdata

    struct Boom: Error {}

    static func outcomes(_ check: Check, root: URL) async throws {
        let executor = ToolExecutor()
        let bad = writeFileCall(path: "relative/path.txt", content: "x")
        _ = try await executor.executeParallel([bad])
        StageMarkers.flush(timeout: 10)
        let recs = records(StageMarkers.logURL).filter { ($0["call"] as? String) == bad.id }
        let exitOf: (String) -> String? = { stage in
            recs.first { $0["stage"] as? String == stage && $0["ev"] as? String == "exit" }?["outcome"] as? String
        }
        check("SM2 a refused write_file records outcome=error on the tool and the file stage",
              exitOf("tool.execute") == "error" && exitOf("fs.write_file") == "error", "\(recs)")

        let ctx = StageMarkers.CallContext(callId: "call_sm_measure", tool: "selftest", depth: 0)
        StageMarkers.$call.withValue(ctx) {
            _ = try? StageMarkers.measure("selftest.throws") { throw Boom() }
            _ = try? StageMarkers.measure("selftest.cancelled") { throw CancellationError() }
        }
        StageMarkers.flush(timeout: 10)
        let m = records(StageMarkers.logURL).filter { ($0["call"] as? String) == "call_sm_measure" && $0["ev"] as? String == "exit" }
        check("SM3 measure records error for a throw and cancelled for CancellationError",
              m.first { $0["stage"] as? String == "selftest.throws" }?["outcome"] as? String == "error"
              && m.first { $0["stage"] as? String == "selftest.cancelled" }?["outcome"] as? String == "cancelled", "\(m)")

        // /deleteuserdata removes logs/: the writer must notice and recreate.
        let logs = StageMarkers.logURL.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: logs)
        StageMarkers.event("selftest.after_wipe", call: nil)
        StageMarkers.flush(timeout: 10)
        let after = records(StageMarkers.logURL)
        check("SM4 after the logs directory is removed the log is recreated (0600) with new records",
              after.contains { $0["stage"] as? String == "selftest.after_wipe" } && mode(StageMarkers.logURL.path) == 0o600,
              "\(after.count) records")
    }

    // MARK: - SM5: tool-path overhead

    static func overhead(_ check: Check) {
        let ctx = StageMarkers.CallContext(callId: "call_sm_overhead", tool: "selftest", depth: 0)
        let n = 5_000
        let start = StageMarkers.monotonicNanos()
        StageMarkers.$call.withValue(ctx) {
            for _ in 0..<n {
                let t = StageMarkers.enter("selftest.overhead")
                StageMarkers.exit(t, .ok)
            }
        }
        let perPairMicros = Double(StageMarkers.monotonicNanos() - start) / Double(n) / 1000
        StageMarkers.flush(timeout: 20)
        print("  · enter+exit pair on the tool path: \(String(format: "%.2f", perPairMicros)) µs average (\(n) pairs)")
        check("SM5 enter+exit costs well under 100 µs on the tool path", perPairMicros < 100,
              String(format: "%.2f µs", perPairMicros))
    }

    // MARK: - SM6–SM10: child processes

    static func childRows(_ check: Check, root: URL) throws {
        // SM6 crash durability: the child never flushes; the parent sees the
        // record on disk while the child is alive, then SIGKILLs it.
        let crashLog = root.appendingPathComponent("crash.log")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: selfPath)
        p.arguments = ["__stage-markers-selftest", "--child", "hold"]
        var env = ProcessInfo.processInfo.environment
        env["BRIGLIA_STAGE_MARKERS_PATH"] = crashLog.path
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        var seen = false
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if records(crashLog).contains(where: { $0["stage"] as? String == "selftest.crash_open" }) { seen = true; break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        kill(p.processIdentifier, SIGKILL)
        p.waitUntilExit()
        let crashRecs = records(crashLog)
        let text = (try? String(contentsOf: crashLog, encoding: .utf8)) ?? ""
        let unclosed = StageMarkersReader.unclosed(text.split(separator: "\n").map(String.init))
        check("SM6 a record is on disk without any flush and survives SIGKILL; the reader lists it as unclosed",
              seen && p.terminationReason == .uncaughtSignal
              && crashRecs.contains { $0["stage"] as? String == "selftest.crash_open" && $0["ev"] as? String == "enter" }
              && unclosed.contains { $0.contains("selftest.crash_open") },
              "seen=\(seen) records=\(crashRecs.count) unclosed=\(unclosed.count)")

        // SM7 stall reporter: one report, the stage keeps running and ends ok.
        let stallLog = root.appendingPathComponent("stall.log")
        let stall = try runChildProcess("stall", env: ["BRIGLIA_STAGE_MARKERS_PATH": stallLog.path,
                                                        "BRIGLIA_STALL_REPORT_SECONDS": "0.5"], timeout: 30)
        let s = records(stallLog)
        let reports = s.filter { $0["ev"] as? String == "stall_suspected" }
        let slowExit = s.first { $0["stage"] as? String == "selftest.slow" && $0["ev"] as? String == "exit" }
        check("SM7a exactly one stall report, for the slow stage only",
              reports.count == 1 && reports.first?["stage"] as? String == "selftest.slow", "\(reports.count) reports")
        check("SM7b the reporter did not cancel or fail the stage: it finished ok after ~2 s and the body completed",
              stall.status == 0 && stall.stdout.contains("BODY-COMPLETED") && slowExit?["outcome"] as? String == "ok"
              && ((slowExit?["elapsed_ms"] as? Double) ?? 0) >= 1900, "status \(stall.status) \(slowExit ?? [:])")
        let report = reports.first ?? [:]
        let openList = report["open_stages"] as? [[String: Any]] ?? []
        var threadsOK = true
        #if os(Linux)
        threadsOK = ((report["threads"] as? [[String: Any]]) ?? []).contains { $0["wchan"] != nil && $0["state"] != nil }
        #endif
        check("SM7c the report lists open stages, the last marker, the call, and (Linux) thread wait states",
              openList.contains { $0["stage"] as? String == "selftest.slow" } && report["last_marker"] != nil
              && report["call"] as? String == "call_sm_stall" && (report["note"] as? String)?.contains("NOT cancelled") == true
              && threadsOK, "\(report)")
        check("SM7d the report is also written to stderr", stall.stderr.contains("STALL SUSPECTED"), stall.stderr)

        // SM8 disabled switch.
        let offLog = root.appendingPathComponent("disabled.log")
        let off = try runChildProcess("basic", env: ["BRIGLIA_STAGE_MARKERS_PATH": offLog.path,
                                                      "BRIGLIA_STAGE_MARKERS": "0"], timeout: 30)
        check("SM8 BRIGLIA_STAGE_MARKERS=0 writes nothing", off.status == 0
              && !FileManager.default.fileExists(atPath: offLog.path), "status \(off.status)")

        // SM9 rotation.
        let rotLog = root.appendingPathComponent("rotate.log")
        let rot = try runChildProcess("rotate", env: ["BRIGLIA_STAGE_MARKERS_PATH": rotLog.path,
                                                       "BRIGLIA_STAGE_MARKERS_MAX_BYTES": "4096"], timeout: 30)
        let curSize = ((try? FileManager.default.attributesOfItem(atPath: rotLog.path))?[.size] as? NSNumber)?.intValue ?? -1
        check("SM9 the log rotates at the size cap to .1; both stay 0600 and bounded",
              rot.status == 0 && FileManager.default.fileExists(atPath: rotLog.path + ".1")
              && mode(rotLog.path) == 0o600 && mode(rotLog.path + ".1") == 0o600 && curSize >= 0 && curSize < 4096 + 1024,
              "status \(rot.status) size \(curSize)")

        // SM10 a hung log volume (a FIFO nobody reads: open() blocks) must
        // not slow the tool path or block process exit.
        let fifo = root.appendingPathComponent("hung.fifo").path
        _ = mkfifo(fifo, 0o600)
        let hung = try runChildProcess("hung", env: ["BRIGLIA_STAGE_MARKERS_PATH": fifo], timeout: 30)
        let ms = hung.stdout.components(separatedBy: "PAIRS-MS=").last.flatMap {
            Double($0.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first ?? "")
        } ?? -1
        check("SM10 with the log volume hung, 2,000 marker pairs still take < 1 s and the process exits normally",
              !hung.timedOut && hung.status == 0 && ms >= 0 && ms < 1000, "timedOut=\(hung.timedOut) status=\(hung.status) ms=\(ms)")
    }

    // MARK: - SM11: the Git reader barrier, as the markers show it

    /// A fake `git` that prints a SHA and exits 0, leaving a descendant that
    /// keeps ONLY stdin/stdout/stderr open (it closes every other fd, like a
    /// careful daemon) for `hold` seconds.
    static func fakeGitHoldingStdout(in dir: URL, hold: Int) throws -> String {
        let path = dir.appendingPathComponent("fake-git").path
        let script = """
        #!/bin/sh
        python3 -c 'import os,time; os.closerange(3,65536); time.sleep(\(hold))' &
        echo deadbeefcafe
        exit 0
        """
        FileManager.default.createFile(atPath: path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o700])
        return path
    }

    static func gitReaderBarrier(_ check: Check, root: URL) throws {
        let dir = root.appendingPathComponent("fakegit")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fake = try fakeGitHoldingStdout(in: dir, hold: 3)
        let ctx = StageMarkers.CallContext(callId: "call_sm_git", tool: "write_file", depth: 0)
        let start = Date()
        let out = StageMarkers.$call.withValue(ctx) {
            GitCheckpointTracker.runGit(["stash", "create"], in: dir.path, timeoutSeconds: 1, executable: fake)
        }
        let elapsed = Date().timeIntervalSince(start)
        StageMarkers.flush(timeout: 10)
        let recs = records(StageMarkers.logURL).filter { ($0["call"] as? String) == "call_sm_git" && $0["ev"] as? String == "exit" }
        let barrier = recs.first { $0["stage"] as? String == "git.drain_stdout_barrier" }
        let waitExit = recs.first { $0["stage"] as? String == "git.wait_exit" }
        print("  · fake git (descendant holds stdout 3 s, timeout 1 s): runGit returned after \(String(format: "%.2f", elapsed)) s, barrier stage \(barrier?["elapsed_ms"] ?? "-") ms")
        // v0.2.40 behaviour, made visible: git exits at once (wait_exit ok),
        // then the reader barrier waits for the descendant — past the 1 s
        // timeout, unbounded in general.
        check("SM11 the markers localize the Git reader wait: wait_exit ok, then the stdout barrier holds past the git timeout",
              out == "deadbeefcafe" && waitExit?["outcome"] as? String == "ok"
              && ((barrier?["elapsed_ms"] as? Double) ?? 0) >= 2500 && elapsed >= 2.5,
              "out=\(out ?? "nil") elapsed=\(elapsed) barrier=\(barrier ?? [:])")
    }

    // MARK: - Child modes

    static func runChild(_ mode: String) async throws {
        applyChildFileSizeLimit()
        let ctx = StageMarkers.CallContext(callId: "call_sm_\(mode)", tool: "selftest", depth: 0)
        switch mode {
        case "hold":
            StageMarkers.$call.withValue(ctx) { _ = StageMarkers.enter("selftest.crash_open") }
            // No flush: the parent must find the record on disk by itself.
            Thread.sleep(forTimeInterval: 60)
        case "stall":
            StageMarkers.$call.withValue(ctx) {
                let slow = StageMarkers.enter("selftest.slow")
                Thread.sleep(forTimeInterval: 2.0)
                StageMarkers.exit(slow, .ok)
                let fast = StageMarkers.enter("selftest.fast")
                Thread.sleep(forTimeInterval: 0.05)
                StageMarkers.exit(fast, .ok)
            }
            StageMarkers.flush(timeout: Double(ProcessInfo.processInfo.environment["SM_FLUSH_TIMEOUT"] ?? "") ?? 10)
            print("BODY-COMPLETED")
        case "basic":
            StageMarkers.$call.withValue(ctx) {
                let t = StageMarkers.enter("selftest.basic")
                StageMarkers.event("selftest.point")
                StageMarkers.exit(t, .ok)
            }
            StageMarkers.flush(timeout: 10)
        case "rotate":
            StageMarkers.$call.withValue(ctx) {
                for i in 0..<300 {
                    StageMarkers.event("selftest.rotate", detail: "record \(i) " + String(repeating: "r", count: 40))
                }
            }
            StageMarkers.flush(timeout: 10)
        case "hung":
            let start = StageMarkers.monotonicNanos()
            StageMarkers.$call.withValue(ctx) {
                for _ in 0..<2_000 {
                    let t = StageMarkers.enter("selftest.hung")
                    StageMarkers.exit(t, .ok)
                }
            }
            let ms = Double(StageMarkers.monotonicNanos() - start) / 1_000_000
            print("PAIRS-MS=\(ms)")
            // Normal exit while the writer thread is stuck in open().
        case "bench":
            try await benchChild()
        case "recover", "flood":
            try round2Child(mode, ctx: ctx)
        default:
            throw ValidationError("unknown child mode \(mode)")
        }
    }

    // MARK: - Bench (not a pass/fail row)

    static func runBench(count: Int, root: URL) throws {
        print("write_file latency, \(count) calls per run, fresh executor per run (one git checkpoint per run)")
        var on: [Double] = [], off: [Double] = []
        for round in 0..<5 {
            for enabled in (round % 2 == 0 ? [true, false] : [false, true]) {
                let dir = root.appendingPathComponent("bench-\(round)-\(enabled)")
                // Fresh roots per run: the files ledger grows with every
                // write and would otherwise make later runs slower.
                var env = ["SM_BENCH_DIR": dir.appendingPathComponent("work").path, "SM_BENCH_COUNT": "\(count)",
                           "XDG_DATA_HOME": dir.appendingPathComponent("data").path,
                           "XDG_CONFIG_HOME": dir.appendingPathComponent("config").path,
                           "BRIGLIA_STAGE_MARKERS_PATH": root.appendingPathComponent("bench-\(round).log").path]
                if let custom = ProcessInfo.processInfo.environment["SM_BENCH_LOG"] {
                    env["BRIGLIA_STAGE_MARKERS_PATH"] = custom
                }
                if !enabled { env["BRIGLIA_STAGE_MARKERS"] = "0" }
                let run = try runChildProcess("bench", env: env, timeout: 600)
                let avg = run.stdout.components(separatedBy: "AVG-MS=").last.flatMap {
                    Double($0.split(separator: "\n").first ?? "")
                } ?? -1
                if enabled { on.append(avg) } else { off.append(avg) }
                print("  run \(round + 1) markers \(enabled ? "on " : "off"): \(String(format: "%.3f", avg)) ms per write_file")
            }
        }
        let mean: ([Double]) -> Double = { $0.reduce(0, +) / Double(max(1, $0.count)) }
        let median: ([Double]) -> Double = { values in
            let sorted = values.sorted()
            return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        }
        print(String(format: "mean on %.3f ms, off %.3f ms, difference %.3f ms per call", mean(on), mean(off), mean(on) - mean(off)))
        print(String(format: "median on %.3f ms, off %.3f ms, difference %.3f ms per call", median(on), median(off), median(on) - median(off)))
    }

    static func benchChild() async throws {
        let env = ProcessInfo.processInfo.environment
        let dir = URL(fileURLWithPath: env["SM_BENCH_DIR"] ?? "/tmp/sm-bench")
        let count = Int(env["SM_BENCH_COUNT"] ?? "200") ?? 200
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        shell("git init -q . && printf 'one\\n' > tracked.txt && git add tracked.txt && git -c user.name=t -c user.email=t@example.invalid commit -q -m init && printf 'two\\n' > tracked.txt", in: dir.path)
        let executor = ToolExecutor()
        // Warm-up call (first checkpoint, lazy singletons) is excluded.
        _ = try await executor.execute(writeFileCall(path: dir.appendingPathComponent("warm.txt").path, content: "w\n"))
        var totalNanos: UInt64 = 0
        for i in 0..<count {
            let call = writeFileCall(path: dir.appendingPathComponent("f\(i).txt").path, content: "line \(i)\n")
            let start = StageMarkers.monotonicNanos()
            _ = try await executor.execute(call)
            totalNanos += StageMarkers.monotonicNanos() - start
        }
        print("AVG-MS=\(Double(totalNanos) / Double(count) / 1_000_000)")
    }
}
