import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Hidden diagnostic: a background job that floods tens of MB of output
/// WITHOUT a newline must not wedge the background-job pipeline.
///
/// Field case (v0.2.50, benchmark run scored-briglia-1, 2026-10-08): a MIPS
/// interpreter spammed one 69,914,227-character line to stdout in ~2 min;
/// the next bash_manage(output) never returned and one daemon thread sat at
/// 100% CPU for over an hour. Each row here times a real registry job end to
/// end: start → process exit → settlement → bash_manage(output).
///
/// Env knobs (exploration only; the smoke suite uses the defaults):
///   BRIGLIA_FLOOD_MB      payload size per row (default 70)
///   BRIGLIA_FLOOD_ROWS    comma list of rows to run (default: all)
///   BRIGLIA_FLOOD_REPLAY  path of a captured output file; adds row R, which
///                         replays it (cat) as a background job's stdout
///   BRIGLIA_FLOOD_BUDGET  seconds each row may take from job start to the
///                         answered output() call (default 60; v0.2.50 needs
///                         well over 360 s for the 70 MB no-newline row on an
///                         M4, over an hour in the Linux field case)
struct BashFloodSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__bash-flood-selftest",
        abstract: "Internal: background bash output floods (huge newline-free lines) stay bounded.",
        shouldDisplay: false
    )

    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("briglia-bash-flood-selftest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        setenv("XDG_DATA_HOME", tempRoot.appendingPathComponent("data").path, 1)
        setenv("XDG_CONFIG_HOME", tempRoot.appendingPathComponent("config").path, 1)

        let env = ProcessInfo.processInfo.environment
        let mb = Int(env["BRIGLIA_FLOOD_MB"] ?? "") ?? 70
        let budget = Double(env["BRIGLIA_FLOOD_BUDGET"] ?? "") ?? 60
        let rowFilter = env["BRIGLIA_FLOOD_ROWS"].map { Set($0.split(separator: ",").map(String.init)) }

        // A wedged row blocks a thread inside the registry (that IS the
        // bug), so the only reliable way out is a process-level watchdog
        // that names the row it caught.
        let currentRow = FloodRowMarker()
        let watchdogSeconds = UInt64(max(240, Int(budget) * 4 + 60))
        let watchdog = Task.detached {
            try? await Task.sleep(nanoseconds: watchdogSeconds * 1_000_000_000)
            if !Task.isCancelled {
                print("  ✖ WATCHDOG: row '\(currentRow.get())' still running after \(watchdogSeconds)s — background pipeline wedged")
                print("FAIL: bash flood selftest hung")
                Foundation.exit(3)
            }
        }
        defer { watchdog.cancel() }

        var failures = 0
        func check(_ label: String, _ ok: Bool, detail: String = "") {
            print("  \(ok ? "✔" : "✖") \(label)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }
        func wants(_ row: String) -> Bool { rowFilter?.contains(row) ?? true }

        let bytes = mb * 1_048_576
        print("Background flood (\(mb) MB per row, \(Int(budget))s budget from job start)")

        // Row F1 — the field shape: one giant line, stdio-buffered writes.
        if wants("F1") {
            currentRow.set("F1")
            let r = await FloodRow.run(
                label: "F1 no-newline flood",
                command: FloodRow.awkCommand(bytes: bytes, newlineEvery: 0))
            _ = r.report(check: check, budget: budget, expectBytes: bytes)
        }
        // Row F2 — control: same volume, short lines.
        if wants("F2") {
            currentRow.set("F2")
            let r = await FloodRow.run(
                label: "F2 newline flood (control)",
                command: FloodRow.awkCommand(bytes: bytes, newlineEvery: 40))
            _ = r.report(check: check, budget: budget,
                                 expectBytes: FloodRow.expectedBytes(bytes: bytes, newlineEvery: 40))
        }
        // Row F3 — the same giant line on stderr.
        if wants("F3") {
            currentRow.set("F3")
            let r = await FloodRow.run(
                label: "F3 no-newline flood on stderr",
                command: FloodRow.awkCommand(bytes: bytes, newlineEvery: 0) + " 1>&2",
                stream: "stderr")
            _ = r.report(check: check, budget: budget, expectBytes: bytes)
        }
        // Row F4 — attached (foreground) bash shares the sinks; it must stay
        // bounded too.
        if wants("F4") {
            currentRow.set("F4")
            let t0 = Date()
            let result = await BashTools.runAttached(
                command: FloodRow.awkCommand(bytes: bytes, newlineEvery: 0))
            let wall = Date().timeIntervalSince(t0)
            let p = (try? JSONSerialization.jsonObject(with: Data(result.content.utf8))) as? [String: Any] ?? [:]
            let spill = p["stdout_full_output_path"] as? String
            let size = spill.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0))?[.size] as? Int } ?? -1
            check("F4 attached no-newline flood: returns, complete spill",
                  p["success"] as? Bool == true && size == bytes && wall < budget * 3,
                  detail: "wall=\(String(format: "%.1f", wall))s success=\(p["success"] ?? "?") spill=\(size)")
            if let spill { try? FileManager.default.removeItem(atPath: spill) }
        }
        // Row F5 — output() while the flood is still running must answer
        // promptly (the field case: the model polled a live job).
        if wants("F5") {
            currentRow.set("F5")
            _ = await FloodRow.midStream(bytes: bytes, budget: budget, check: check)
        }

        // Row F6 — redaction and watches still work inside a flood: a
        // secret (synthetic bot token) split across chunks in a newline-free
        // flood, then a short marker line for a watch.
        if wants("F6") {
            currentRow.set("F6")
            _ = await FloodRow.secretsAndWatches(bytes: min(bytes, 16 * 1_048_576),
                                                         budget: budget, check: check)
        }
        // Row F7 — with secrets configured, the live view of a RUNNING job
        // still shows the newest bytes (held in the redactor's carry window).
        if wants("F7") {
            currentRow.set("F7")
            _ = await FloodRow.liveCarryView(check: check)
        }
        // Row R — replay a captured field file (manual runs only).
        if let replay = env["BRIGLIA_FLOOD_REPLAY"], !replay.isEmpty, wants("R") {
            currentRow.set("R")
            let size = (try? FileManager.default.attributesOfItem(atPath: replay))?[.size] as? Int ?? -1
            let quoted = "'" + replay.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let r = await FloodRow.run(label: "R replay \((replay as NSString).lastPathComponent)",
                                       command: "cat " + quoted)
            _ = r.report(check: check, budget: budget, expectBytes: size)
        }
        // Units — the line splitter and bounded-text helpers directly.
        if wants("U") {
            currentRow.set("U")
            _ = FloodRow.units(check: check)
        }

        currentRow.set("done")
        if failures == 0 {
            print("PASS: bash flood selftest")
        } else {
            print("FAIL: bash flood selftest — \(failures) check(s) failed")
            throw ExitCode(1)
        }
    }
}

final class FloodRowMarker: @unchecked Sendable {
    private let lock = NSLock()
    private var row = "setup"
    func set(_ r: String) { lock.lock(); row = r; lock.unlock() }
    func get() -> String { lock.lock(); defer { lock.unlock() }; return row }
}

struct FloodRow {
    let label: String
    let stream: String
    let exitedAfter: Double
    let settledAfter: Double
    let outputAfter: Double
    let payload: [String: Any]
    let pendingLineBytes: Int

    /// stdio-buffered awk writes (like the field interpreter's printf to a
    /// pipe); `newlineEvery` 0 = never emit a newline.
    static let unit = "Error: Unknown format specifier "

    static func awkCommand(bytes: Int, newlineEvery: Int) -> String {
        let nl = newlineEvery > 0 ? " if (i % \(newlineEvery) == \(newlineEvery - 1)) printf \"\\n\";" : ""
        // `bytes` payload bytes (whole units, then a filler tail), plus one
        // newline after every `newlineEvery` units — see expectedBytes.
        return "LC_ALL=C awk 'BEGIN{u=\"\(unit)\"; n=int(\(bytes)/length(u)); r=\(bytes)-n*length(u); for(i=0;i<n;i++){ printf \"%s\", u;\(nl) }; for(j=0;j<r;j++) printf \"x\" }'"
    }

    static func expectedBytes(bytes: Int, newlineEvery: Int) -> Int {
        guard newlineEvery > 0 else { return bytes }
        return bytes + (bytes / unit.utf8.count) / newlineEvery
    }

    static func run(label: String, command: String, stream: String = "stdout") async -> FloodRow {
        let t0 = Date()
        let started = await BashTools.runBackground(command: command, description: "flood selftest")
        let sp = (try? JSONSerialization.jsonObject(with: Data(started.content.utf8))) as? [String: Any] ?? [:]
        let handle = sp["handle"] as? String ?? ""
        // Exit = the shell process is gone (independent of the pipeline).
        let pid = Int32(sp["pid"] as? Int ?? 0)
        var exitedAt: Double = -1
        while Date().timeIntervalSince(t0) < 600 {
            if pid > 0, kill(pid, 0) != 0 { exitedAt = Date().timeIntervalSince(t0); break }
            if pid <= 0 { exitedAt = Date().timeIntervalSince(t0); break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let outcome = await BackgroundProcessRegistry.shared.awaitSettlement(
            handleId: handle, timeoutNanos: 600_000_000_000)
        let settledAt = Date().timeIntervalSince(t0)
        _ = outcome
        let out = await BashTools.output(handle: handle)
        let outputAt = Date().timeIntervalSince(t0)
        let p = (try? JSONSerialization.jsonObject(with: Data(out.content.utf8))) as? [String: Any] ?? [:]
        let pending = await BackgroundProcessRegistry.shared._testPendingLineBytes(handleId: handle)
        return FloodRow(label: label, stream: stream, exitedAfter: exitedAt,
                        settledAfter: settledAt, outputAfter: outputAt, payload: p,
                        pendingLineBytes: max(pending?.stdout ?? -1, pending?.stderr ?? -1))
    }

    /// Returns the number of failed checks (already counted via `check`).
    func report(check: (String, Bool, String) -> Void, budget: Double,
                expectBytes: Int) -> Int {
        var failed = 0
        func c(_ l: String, _ ok: Bool, _ d: String) { check(l, ok, d); if !ok { failed += 1 } }
        // Measured from job START: the fixed pipeline back-pressures the
        // writer, so "writer exit" moves with processing speed and is not a
        // fair zero point.
        let timing = String(format: "exit=%.1fs settled=%.1fs output=%.1fs", exitedAfter, settledAfter, outputAfter)
        c("\(label): settled + output within \(Int(budget))s of start",
          payload["success"] as? Bool == true && outputAfter < budget, timing)
        let total = payload["\(stream)_total_bytes"] as? Int ?? -1
        let spill = payload["\(stream)_full_output_path"] as? String
        let size = spill.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0))?[.size] as? Int } ?? -1
        c("\(label): byte accounting + complete spill",
          total == expectBytes && size == expectBytes,
          "total_bytes=\(total) spill=\(size) expected=\(expectBytes)")
        let shown = payload[stream] as? String ?? ""
        c("\(label): tail preview present and bounded",
          !shown.isEmpty && shown.utf8.count <= TruncationService.maxBytes + 4096,
          "preview=\(shown.utf8.count)B")
        // The unterminated tail line is held for watches: bounded by the line
        // cap plus secret room, never the whole 70MB line.
        let lineBound = BackgroundProcessRegistry.watchLineCapBytes + 64 * 1024
        c("\(label): pending watch-line buffer bounded",
          pendingLineBytes >= 0 && pendingLineBytes <= lineBound,
          "pending=\(pendingLineBytes)B bound=\(lineBound)B")
        if let spill { try? FileManager.default.removeItem(atPath: spill) }
        return failed
    }

    static func midStream(bytes: Int, budget: Double,
                          check: (String, Bool, String) -> Void) async -> Int {
        var failed = 0
        func c(_ l: String, _ ok: Bool, _ d: String) { check(l, ok, d); if !ok { failed += 1 } }
        // Throttled writer: the flood lasts ~8 s so polls land mid-stream.
        let chunks = 64
        let per = max(1, bytes / chunks)
        let cmd = awkCommand(bytes: per, newlineEvery: 0)
        let loop = "for i in $(seq 1 \(chunks)); do \(cmd); sleep 0.12; done"
        let started = await BashTools.runBackground(command: loop, description: "flood selftest mid-stream")
        let sp = (try? JSONSerialization.jsonObject(with: Data(started.content.utf8))) as? [String: Any] ?? [:]
        let handle = sp["handle"] as? String ?? ""
        var worst: Double = 0
        var polls = 0
        var lastTotal = 0
        var running = true
        let t0 = Date()
        while running && Date().timeIntervalSince(t0) < 600 {
            try? await Task.sleep(nanoseconds: 700_000_000)
            let p0 = Date()
            let out = await BashTools.output(handle: handle, since: lastTotal)
            worst = max(worst, Date().timeIntervalSince(p0))
            polls += 1
            let p = (try? JSONSerialization.jsonObject(with: Data(out.content.utf8))) as? [String: Any] ?? [:]
            lastTotal = p["stdout_total_bytes"] as? Int ?? lastTotal
            running = (p["status"] as? String) == "running"
        }
        _ = await BackgroundProcessRegistry.shared.awaitSettlement(handleId: handle, timeoutNanos: 600_000_000_000)
        let final = await BashTools.output(handle: handle)
        let p = (try? JSONSerialization.jsonObject(with: Data(final.content.utf8))) as? [String: Any] ?? [:]
        c("F5 output() polls during a live flood answer promptly",
          worst < 2.0 && polls >= 3,
          String(format: "polls=%d worst=%.2fs", polls, worst))
        let total = p["stdout_total_bytes"] as? Int ?? -1
        c("F5 final byte accounting", total == per * chunks, "total=\(total) expected=\(per * chunks)")
        if let spill = p["stdout_full_output_path"] as? String { try? FileManager.default.removeItem(atPath: spill) }
        return failed
    }
}
