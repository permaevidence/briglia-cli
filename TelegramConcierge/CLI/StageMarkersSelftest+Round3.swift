import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Round 3 rows (Codex review round 2, 2026-09-28): a write cut inside a
/// multi-byte UTF-8 character must not hide the whole file from the reader
/// or doctor. The damaged line is counted and skipped; every valid record
/// before and after it stays visible, in the current and the rotated file.
/// No row depends on file-mode unreadability, so all run as root.
extension StageMarkersSelftest {

    static let accentedDetail = String(repeating: "é", count: 60)

    /// Child `utf8cut`: one normal record, then a record whose detail is all
    /// `é`, cut by RLIMIT_FSIZE right after the first byte (0xC3) of one of
    /// them, then recovery. The cut offset is computed from a probe render
    /// of the same record shape; the parent verifies the cut really landed
    /// inside a character, so a wrong guess fails loudly.
    static func round3Child(_ mode: String, ctx: StageMarkers.CallContext) throws {
        switch mode {
        case "utf8cut":
            signal(SIGXFSZ, SIG_IGN)
            let path = StageMarkers.logURL.path
            StageMarkers.$call.withValue(ctx) { StageMarkers.event("selftest.before_cut") }
            _ = StageMarkers.flush(timeout: 10)
            let size1 = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.intValue ?? 0
            let probe = StageMarkers.Record(seq: 2, kind: .event, stage: "selftest.cut", token: 0, callId: ctx.callId,
                                            tool: ctx.tool, depth: ctx.depth, round: nil,
                                            monoNanos: StageMarkers.monotonicNanos(), wall: Date().timeIntervalSince1970,
                                            elapsedNanos: nil, outcome: nil, detail: accentedDetail, extraJSON: nil)
            let length = StageMarkers.Engine.render(probe, dropped: 0).utf8.count
            // Line ends `…é"}\n`; the k-th é from the end starts 2k+3 bytes
            // from the end. Keep everything up to and including that 0xC3.
            let k = 20
            setFileSizeLimit(rlim_t(size1 + length - (2 * k + 2)))
            StageMarkers.$call.withValue(ctx) { StageMarkers.event("selftest.cut", detail: accentedDetail) }
            _ = StageMarkers.flush(timeout: 10)
            raiseFileSizeLimit()
            StageMarkers.$call.withValue(ctx) {
                let t = StageMarkers.enter("selftest.after_cut_open")
                _ = t
            }
            _ = StageMarkers.flush(timeout: 10)
            printStats()
        case "doctorline":
            print("DOCTOR: " + StageMarkersReader.doctorLine())
        default:
            throw ValidationError("unknown child mode \(mode)")
        }
    }

    /// Runs the real hidden reader command against a log path.
    static func readerCommand(_ path: String, _ extra: [String] = []) throws -> ChildRun {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: selfPath)
        p.arguments = ["__stage-markers"] + extra
        var env = ProcessInfo.processInfo.environment
        env["BRIGLIA_STAGE_MARKERS_PATH"] = path
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return ChildRun(status: p.terminationStatus, stdout: String(decoding: data, as: UTF8.self), stderr: "", timedOut: false)
    }

    static func damagedEncodingRows(_ check: Check, root: URL) throws {
        // SM15a–c: Codex's reproduction through the real writer.
        let log = root.appendingPathComponent("r4-utf8.log")
        let run = try runChildPiped("utf8cut", env: ["BRIGLIA_STAGE_MARKERS_PATH": log.path], timeout: 30)
        let raw = (try? Data(contentsOf: log)) ?? Data()
        let damaged = raw.split(separator: 0x0A).filter { String(data: Data($0), encoding: .utf8) == nil }
        let cutMidChar = damaged.count == 1 && damaged.first?.last == 0xC3
        let reader = try readerCommand(log.path)
        check("SM15a a write cut inside a multi-byte character: the reader still prints the records before and after it",
              run.status == 0 && cutMidChar && statValue(run.stdout, "failed") == 1
              && reader.stdout.contains("selftest.before_cut") && reader.stdout.contains("selftest.after_cut_open")
              && reader.stdout.contains("\"write_failed_before\":1") && !reader.stdout.contains("no records yet"),
              "cutMidChar=\(cutMidChar) status=\(run.status) reader=\(reader.stdout.prefix(600))")
        check("SM15b the reader discloses the damaged line as invalid UTF-8 (LOSS DETECTED)",
              reader.stdout.contains("LOSS DETECTED") && reader.stdout.contains("1 invalid UTF-8"), reader.stdout)
        let unclosed = try readerCommand(log.path, ["--unclosed"])
        check("SM15c --unclosed still finds the open stage recorded after the damaged line",
              unclosed.stdout.contains("selftest.after_cut_open"), unclosed.stdout)
        let doctor = try runChildPiped("doctorline", env: ["BRIGLIA_STAGE_MARKERS_PATH": log.path], timeout: 30)
        check("SM15d doctor reports the loss including the invalid-UTF-8 line",
              doctor.stdout.contains("LOSS DETECTED") && doctor.stdout.contains("1 invalid UTF-8"), doctor.stdout)

        // SM15e: the damaged file has been rotated to .1; the current file
        // is clean. Both files' valid records show, the damage is counted.
        let rotBase = root.appendingPathComponent("r4-rot.log")
        try raw.write(to: URL(fileURLWithPath: rotBase.path + ".1"))
        let fresh = "{\"v\":1,\"seq\":1,\"t\":\"2026-09-28T00:00:00.000Z\",\"mono_ms\":1.000,\"pid\":999999,\"ev\":\"event\",\"stage\":\"selftest.current_file\"}\n"
        try Data(fresh.utf8).write(to: rotBase)
        let rot = try readerCommand(rotBase.path, ["--last", "100"])
        let rotDoctor = try runChildPiped("doctorline", env: ["BRIGLIA_STAGE_MARKERS_PATH": rotBase.path], timeout: 30)
        check("SM15e damaged rotated file: records from .1 and the current file both show; reader and doctor count the damage",
              rot.stdout.contains("selftest.before_cut") && rot.stdout.contains("selftest.current_file")
              && rot.stdout.contains("1 invalid UTF-8") && rotDoctor.stdout.contains("1 invalid UTF-8"),
              "reader=\(rot.stdout.prefix(500)) doctor=\(rotDoctor.stdout)")

        // SM15f: a log that exists but cannot be read (a directory, which
        // fails as root too) is a READ ERROR, not "no records yet".
        let dirLog = root.appendingPathComponent("r4-is-a-dir.log")
        try FileManager.default.createDirectory(at: dirLog, withIntermediateDirectories: true)
        let dirRead = try readerCommand(dirLog.path)
        let dirDoctor = try runChildPiped("doctorline", env: ["BRIGLIA_STAGE_MARKERS_PATH": dirLog.path], timeout: 30)
        check("SM15f an unreadable log is reported as a read error by the reader and doctor, never as empty",
              dirRead.stdout.contains("READ ERROR") && !dirRead.stdout.contains("no records yet")
              && dirDoctor.stdout.contains("READ ERROR"), "reader=\(dirRead.stdout) doctor=\(dirDoctor.stdout)")
    }
}
