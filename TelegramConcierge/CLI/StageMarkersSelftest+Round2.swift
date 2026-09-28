import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Round 2 rows (Codex review 2026-09-28): R1 a custom log path never
/// changes an existing directory's mode; R2 failed and partial writes are
/// detected, disclosed and recovered from; R3 the watchdog's complete stall
/// report reaches stderr while the log writer is blocked. None of these rows
/// depends on file-mode unreadability, so they run as root too.
extension StageMarkersSelftest {

    // MARK: - Child helpers

    /// `SM_RLIMIT_FSIZE=<bytes>`: cap the file size for this child (EFBIG
    /// and short writes without filling a disk). SIGXFSZ is ignored so the
    /// write returns an error instead of killing the process.
    static func applyChildFileSizeLimit() {
        guard let raw = ProcessInfo.processInfo.environment["SM_RLIMIT_FSIZE"], let bytes = UInt64(raw) else { return }
        signal(SIGXFSZ, SIG_IGN)
        setFileSizeLimit(rlim_t(bytes))
    }

    static func setFileSizeLimit(_ soft: rlim_t) {
        var rl = rlimit()
        #if os(Linux)
        let resource = __rlimit_resource_t(RLIMIT_FSIZE.rawValue)
        #else
        let resource = RLIMIT_FSIZE
        #endif
        _ = getrlimit(resource, &rl)
        rl.rlim_cur = min(soft, rl.rlim_max)
        _ = setrlimit(resource, &rl)
    }

    static func raiseFileSizeLimit() {
        var rl = rlimit()
        #if os(Linux)
        let resource = __rlimit_resource_t(RLIMIT_FSIZE.rawValue)
        #else
        let resource = RLIMIT_FSIZE
        #endif
        _ = getrlimit(resource, &rl)
        rl.rlim_cur = rl.rlim_max
        _ = setrlimit(resource, &rl)
    }

    static func printStats() {
        let st = StageMarkers.stats()
        print("STATS written=\(st.written) failed=\(st.failed) dropped=\(st.dropped)")
    }

    static func round2Child(_ mode: String, ctx: StageMarkers.CallContext) throws {
        switch mode {
        case "recover":
            StageMarkers.$call.withValue(ctx) {
                for i in 0..<20 { StageMarkers.event("selftest.while_full", detail: "record \(i)") }
            }
            let first = StageMarkers.flush(timeout: 10)
            raiseFileSizeLimit()
            StageMarkers.$call.withValue(ctx) { StageMarkers.event("selftest.after_recover") }
            let second = StageMarkers.flush(timeout: 10)
            print("FLUSH=\(first && second)")
        case "flood":
            let start = StageMarkers.monotonicNanos()
            StageMarkers.$call.withValue(ctx) {
                for _ in 0..<1_000 {
                    let t = StageMarkers.enter("selftest.flood")
                    StageMarkers.exit(t, .ok)
                }
            }
            print("PAIRS-MS=\(Double(StageMarkers.monotonicNanos() - start) / 1_000_000)")
            print("FLUSH=\(StageMarkers.flush(timeout: 20))")
        default:
            throw ValidationError("unknown child mode \(mode)")
        }
        printStats()
    }

    /// Like `runChildProcess`, but stdout/stderr are PIPES: a file-size
    /// limit applies to every regular file the child writes, including
    /// redirected output files, and would truncate the evidence.
    static func runChildPiped(_ mode: String, env extra: [String: String], timeout: TimeInterval) throws -> ChildRun {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: selfPath)
        p.arguments = ["__stage-markers-selftest", "--child", mode]
        var env = ProcessInfo.processInfo.environment
        for (k, v) in extra { env[k] = v }
        p.environment = env
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        try p.run()
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter()
        Thread.detachNewThread { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        Thread.detachNewThread { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while p.isRunning {
            if Date() > deadline { timedOut = true; kill(p.processIdentifier, SIGKILL); break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        p.waitUntilExit()
        _ = group.wait(timeout: .now() + 10)
        return ChildRun(status: p.terminationStatus, stdout: String(decoding: outData, as: UTF8.self),
                        stderr: String(decoding: errData, as: UTF8.self), timedOut: timedOut)
    }

    static func statValue(_ out: String, _ key: String) -> Int {
        guard let range = out.range(of: key + "=") else { return -1 }
        let rest = out[range.upperBound...].prefix { $0.isNumber }
        return Int(rest) ?? -1
    }

    static func lines(_ path: String) -> [String] {
        ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    // MARK: - SM12: custom log path (Codex R1)

    static func customPathRows(_ check: Check, root: URL) throws {
        let fm = FileManager.default
        // SM12a: Codex's reproduction — an existing 0755 parent.
        let shared = root.appendingPathComponent("r1-shared")
        try fm.createDirectory(at: shared, withIntermediateDirectories: true)
        _ = chmod(shared.path, 0o755)
        let logA = shared.appendingPathComponent("markers.log")
        let a = try runChildProcess("basic", env: ["BRIGLIA_STAGE_MARKERS_PATH": logA.path], timeout: 30)
        check("SM12a custom path in an existing 0755 directory: the directory stays 0755, the log is 0600 with records",
              a.status == 0 && mode(shared.path) == 0o755 && mode(logA.path) == 0o600 && !records(logA).isEmpty,
              "status \(a.status) dir \(String(mode(shared.path), radix: 8)) log \(String(mode(logA.path), radix: 8))")

        // SM12b: the parent is a symlink to a 0755 directory.
        let target = root.appendingPathComponent("r1-target")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        _ = chmod(target.path, 0o755)
        let link = root.appendingPathComponent("r1-link")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        let b = try runChildProcess("basic", env: ["BRIGLIA_STAGE_MARKERS_PATH": link.appendingPathComponent("markers.log").path],
                                    timeout: 30)
        let logB = target.appendingPathComponent("markers.log")
        check("SM12b custom path under a symlinked parent: the symlink's 0755 target is not tightened",
              b.status == 0 && mode(target.path) == 0o755 && mode(logB.path) == 0o600 && !records(logB).isEmpty,
              "status \(b.status) target \(String(mode(target.path), radix: 8))")

        // SM12c: missing directories are created private; the existing
        // ancestor keeps its mode.
        let outer = root.appendingPathComponent("r1-outer")
        try fm.createDirectory(at: outer, withIntermediateDirectories: true)
        _ = chmod(outer.path, 0o755)
        let new1 = outer.appendingPathComponent("new1"), new2 = new1.appendingPathComponent("new2")
        let logC = new2.appendingPathComponent("markers.log")
        let c = try runChildProcess("basic", env: ["BRIGLIA_STAGE_MARKERS_PATH": logC.path], timeout: 30)
        check("SM12c custom path with missing directories: those are created 0700, the existing ancestor stays 0755",
              c.status == 0 && mode(outer.path) == 0o755 && mode(new1.path) == 0o700 && mode(new2.path) == 0o700
              && mode(logC.path) == 0o600 && !records(logC).isEmpty,
              "outer \(String(mode(outer.path), radix: 8)) new1 \(String(mode(new1.path), radix: 8)) new2 \(String(mode(new2.path), radix: 8))")
    }

    // MARK: - SM13: failed and partial writes (Codex R2)

    static func writeFailureRows(_ check: Check, root: URL) throws {
        // SM13a/b: Codex's reproduction — a 100-byte file-size limit.
        let logA = root.appendingPathComponent("r2-limited.log")
        let a = try runChildPiped("basic", env: ["BRIGLIA_STAGE_MARKERS_PATH": logA.path, "SM_RLIMIT_FSIZE": "100"],
                                    timeout: 30)
        let sizeA = ((try? FileManager.default.attributesOfItem(atPath: logA.path))?[.size] as? NSNumber)?.intValue ?? -1
        check("SM13a a write that fails after a partial record is disclosed on stderr, and the record is copied there",
              a.status == 0 && sizeA == 100 && a.stderr.contains("[StageMarkers] cannot write")
              && a.stderr.contains("[StageMarkers-unwritten]") && a.stderr.contains("selftest.basic"),
              "status \(a.status) size \(sizeA) stderr=\(a.stderr)")
        let checkA = StageMarkersReader.integrity(lines(logA.path))
        check("SM13b the reader flags the truncated file as lossy (malformed tail)",
              !checkA.isClean && checkA.malformed == 1 && checkA.summary.contains("LOSS DETECTED"), checkA.summary)

        // SM13c/d: recovery — a 1,100-byte limit (not a multiple of the ~200-byte records) lets the first records
        // through, then one is cut short and the rest fail; the limit is
        // lifted, the next record lands on its own parseable line and
        // reports how many were not written.
        let logC = root.appendingPathComponent("r2-recover.log")
        let c = try runChildPiped("recover", env: ["BRIGLIA_STAGE_MARKERS_PATH": logC.path, "SM_RLIMIT_FSIZE": "1100"],
                                    timeout: 30)
        let recs = records(logC)
        let after = recs.first { $0["stage"] as? String == "selftest.after_recover" }
        let failed = statValue(c.stdout, "failed")
        check("SM13c after recovery the fragment is terminated, the next record parses and carries write_failed_before; stderr says it recovered",
              c.status == 0 && c.stdout.contains("FLUSH=true") && failed > 0
              && (after?["write_failed_before"] as? Int) == failed && c.stderr.contains("log writes recovered"),
              "status \(c.status) failed=\(failed) after=\(after ?? [:]) stderr=\(c.stderr.suffix(300))")
        let checkC = StageMarkersReader.integrity(lines(logC.path))
        check("SM13d the reader counts exactly the unwritten records as missing, and one malformed fragment",
              checkC.malformed == 1 && checkC.missing == failed && checkC.reportedUnwritten == failed
              && recs.contains { $0["stage"] as? String == "selftest.while_full" },
              "\(checkC.summary) failed=\(failed)")

        // SM13e: a sink that fails every write — stderr stays bounded, the
        // tool path does not slow down, flush still returns.
        let logE = root.appendingPathComponent("r2-flood.log")
        let e = try runChildPiped("flood", env: ["BRIGLIA_STAGE_MARKERS_PATH": logE.path, "SM_RLIMIT_FSIZE": "0"],
                                    timeout: 60)
        let notices = e.stderr.components(separatedBy: "[StageMarkers] cannot write").count - 1
        let copies = e.stderr.components(separatedBy: "[StageMarkers-unwritten]").count - 1
        let ms = e.stdout.components(separatedBy: "PAIRS-MS=").last.flatMap {
            Double($0.split(separator: "\n").first ?? "")
        } ?? -1
        check("SM13e 2,000 failed records: one notice, 50 copies on stderr, counted, tool path < 1 s, flush returns",
              e.status == 0 && notices == 1 && copies == 50 && statValue(e.stdout, "failed") == 2_000
              && statValue(e.stdout, "written") == 0 && e.stdout.contains("FLUSH=true") && ms >= 0 && ms < 1000,
              "status \(e.status) notices \(notices) copies \(copies) ms \(ms) out=\(e.stdout)")
    }

    // MARK: - SM14: stall report with a blocked writer (Codex R3)

    static func stallReportRows(_ check: Check, root: URL) throws {
        // Codex's reproduction: the log is a FIFO nobody reads, so the
        // writer thread is stuck in open() for the whole run.
        let fifo = root.appendingPathComponent("r3-hung.fifo").path
        _ = mkfifo(fifo, 0o600)
        let run = try runChildProcess("stall", env: ["BRIGLIA_STAGE_MARKERS_PATH": fifo, "BRIGLIA_STALL_REPORT_SECONDS": "0.5",
                                                     "SM_FLUSH_TIMEOUT": "1"], timeout: 30)
        let reports = stallReports(run.stderr)
        let report = reports.first ?? [:]
        let openList = report["open_stages"] as? [[String: Any]] ?? []
        var threadsOK = true
        #if os(Linux)
        threadsOK = ((report["threads"] as? [[String: Any]]) ?? []).contains { $0["wchan"] != nil && $0["state"] != nil }
        #endif
        check("SM14a with the log writer blocked, stderr gets the COMPLETE stall report (open stages, last marker, call, thread states on Linux)",
              run.status == 0 && run.stdout.contains("BODY-COMPLETED") && reports.count == 1
              && report["ev"] as? String == "stall_suspected" && report["stage"] as? String == "selftest.slow"
              && openList.contains { $0["stage"] as? String == "selftest.slow" } && report["last_marker"] != nil
              && report["call"] as? String == "call_sm_stall" && (report["note"] as? String)?.contains("NOT cancelled") == true
              && threadsOK,
              "status \(run.status) reports \(reports.count) stderr=\(run.stderr.prefix(800))")

        // SM14b: with a working log and every record mirrored, the report
        // is on stderr once (the writer does not mirror it again) and in
        // the file once.
        let logB = root.appendingPathComponent("r3-mirror.log")
        let b = try runChildProcess("stall", env: ["BRIGLIA_STAGE_MARKERS_PATH": logB.path, "BRIGLIA_STALL_REPORT_SECONDS": "0.5",
                                                   "BRIGLIA_STAGE_MARKERS_STDERR": "1"], timeout: 30)
        let mirrored = b.stderr.components(separatedBy: "\"ev\":\"stall_suspected\"").count - 1
        let inFile = records(logB).filter { $0["ev"] as? String == "stall_suspected" }.count
        check("SM14b with stderr mirroring on, the stall report appears once on stderr and once in the log",
              b.status == 0 && mirrored == 1 && inFile == 1, "stderr \(mirrored) file \(inFile)")
    }

    static func stallReports(_ stderr: String) -> [[String: Any]] {
        let prefix = "[StageMarkers] STALL REPORT "
        return stderr.split(separator: "\n").compactMap { line in
            guard line.hasPrefix(prefix), let data = String(line.dropFirst(prefix.count)).data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
    }
}
