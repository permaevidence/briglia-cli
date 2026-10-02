import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

extension ProcessPipeSelftest {

    // MARK: - Z3-Z6: ProjectsZipAutoExtractor.runProcess with stand-ins

    static func zipRun(_ exe: String, timeout: TimeInterval = ProjectsZipAutoExtractor.unzipTimeout) async -> (value: String?, elapsed: TimeInterval) {
        await bounded { () -> String in
            do {
                return "OK:" + (try ProjectsZipAutoExtractor.runProcess(
                    executablePath: exe, arguments: [], context: "Failed to inspect ZIP archive.", timeout: timeout))
            } catch {
                let e = error as NSError
                return "ERR \(e.code):" + e.localizedDescription
            }
        }
    }

    static func zipStandIns(_ check: Check, dir: URL) async {
        let big = script(dir, "zip-1mb", flood(megabyte, "z"))
        let r1 = await zipRun(big)
        check("Z3 1 MB of stdout comes back complete (\(secs(r1.elapsed)) s)",
              r1.value == "OK:" + String(repeating: "z", count: megabyte) && r1.elapsed < promptBound,
              "\(r1.value?.utf8.count ?? -1) bytes")
        let noisy = script(dir, "zip-noisy", flood(megabyte, "e", toStderr: true) + "\nprintf 'a.txt\\nb.txt\\n'")
        let r2 = await zipRun(noisy)
        check("Z4 1 MB on stderr cannot block; stdout exact (\(secs(r2.elapsed)) s)",
              r2.value == "OK:a.txt\nb.txt\n" && r2.elapsed < promptBound, String((r2.value ?? "hung").prefix(80)))
    }

    static func zipErrorsAndTimeout(_ check: Check, dir: URL) async {
        let fails = script(dir, "zip-fail", "echo '  boom  ' 1>&2\nexit 3")
        let r1 = await zipRun(fails)
        check("Z5a failure text unchanged: context + trimmed stderr, code = exit status",
              r1.value == "ERR 3:Failed to inspect ZIP archive. boom", r1.value ?? "hung")
        let silent = script(dir, "zip-silent", "exit 2")
        let r2 = await zipRun(silent)
        check("Z5b silent failure text unchanged",
              r2.value == "ERR 2:Failed to inspect ZIP archive. Process exited with code 2", r2.value ?? "hung")
        let stuck = script(dir, "zip-stuck", "exec sleep 30")
        let r3 = await zipRun(stuck, timeout: 0.5)
        check("Z6a a stuck unzip hits the deadline: clear failure (\(secs(r3.elapsed)) s)",
              r3.value == "ERR \(ETIMEDOUT):Failed to inspect ZIP archive. unzip did not finish within 0.5 seconds and was stopped."
              && r3.elapsed < promptBound, r3.value ?? "hung")
        check("Z6b the stuck unzip was killed and reaped",
              DiffPipeSelftest.childPids(named: ["sleep", "zip-stuck"]).isEmpty, "")
        let streaming = script(dir, "zip-yes", "exec yes")
        let r4 = await zipRun(streaming, timeout: 0.5)
        check("Z6c an endlessly writing unzip hits the deadline and is reaped (\(secs(r4.elapsed)) s)",
              (r4.value ?? "").hasPrefix("ERR \(ETIMEDOUT):") && r4.elapsed < promptBound
              && DiffPipeSelftest.childPids(named: ["yes", "zip-yes"]).isEmpty, String((r4.value ?? "hung").prefix(80)))
        check("Z6d production deadline is 30 minutes", ProjectsZipAutoExtractor.unzipTimeout == 1_800, "")
    }

    // MARK: - G1-G6: GoogleWorkspaceService.runBlockingProcess / runProcessAsync

    typealias GwsResult = GoogleWorkspaceService.ProcessRunResult

    static func gwsRun(_ exe: String, timeout: Int = 10) async -> (value: GwsResult?, elapsed: TimeInterval) {
        await bounded { GoogleWorkspaceService.runBlockingProcess(executable: exe, args: [], timeoutSeconds: timeout) }
    }

    static func gwsLargeOutput(_ check: Check, dir: URL) async {
        let mid = script(dir, "gws-100k", flood(100_000, "m"))
        let r1 = await gwsRun(mid)
        check("G1 ~100 KB of stdout comes back complete (\(secs(r1.elapsed)) s)",
              r1.value?.stdout == String(repeating: "m", count: 100_000) && r1.value?.failureDetail == nil
              && r1.elapsed < promptBound, "\(r1.value?.stdout?.utf8.count ?? -1) bytes, \(r1.value?.failureDetail ?? "")")
        let big = script(dir, "gws-1mb", flood(megabyte, "g"))
        let r2 = await gwsRun(big)
        check("G2 1 MB of stdout comes back complete (\(secs(r2.elapsed)) s)",
              r2.value?.stdout == String(repeating: "g", count: megabyte) && r2.elapsed < promptBound,
              "\(r2.value?.stdout?.utf8.count ?? -1) bytes, \(r2.value?.failureDetail ?? "")")
        let r3 = await bounded { await GoogleWorkspaceService.runProcessAsync(executable: big, args: [], timeoutSeconds: 10) }
        check("G3 runProcessAsync: 1 MB complete (\(secs(r3.elapsed)) s)",
              r3.value?.stdout?.utf8.count == megabyte && r3.elapsed < promptBound, r3.value?.failureDetail ?? "")
        let noisy = script(dir, "gws-noisy", flood(megabyte, "n", toStderr: true) + "\nprintf '{\"ok\":true}'")
        let r4 = await gwsRun(noisy)
        check("G4 1 MB on stderr cannot block; stdout exact, stderr head = first 200 chars (\(secs(r4.elapsed)) s)",
              r4.value?.stdout == "{\"ok\":true}" && r4.value?.stderrHead == String(repeating: "n", count: 200)
              && r4.elapsed < promptBound, r4.value?.failureDetail ?? "hung")
    }

    static func gwsErrorsAndTimeout(_ check: Check, dir: URL) async {
        let fails = script(dir, "gws-fail", "printf 'partial'\necho ' nope ' 1>&2\nexit 3")
        let r1 = await gwsRun(fails)
        check("G5a failure unchanged: exit + stderr head, no stdout",
              r1.value?.stdout == nil && r1.value?.failureDetail == "exit 3: nope" && r1.value?.stderrHead == "nope",
              "\(r1.value?.failureDetail ?? "hung")")
        let small = script(dir, "gws-small", "printf 'hello\\n'")
        let r2 = await gwsRun(small)
        check("G5b small output byte-identical, no stderr head",
              r2.value?.stdout == "hello\n" && r2.value?.stderrHead == nil && r2.value?.failureDetail == nil, "")
        let stubborn = script(dir, "gws-stuck", "trap '' TERM\nexec sleep 30")
        let r3 = await gwsRun(stubborn, timeout: 1)
        check("G6a a child ignoring SIGTERM: \"timed out after 1s\" (\(secs(r3.elapsed)) s)",
              r3.value?.failureDetail == "timed out after 1s" && r3.value?.stdout == nil && r3.elapsed < promptBound,
              r3.value?.failureDetail ?? "hung")
        let streaming = script(dir, "gws-yes", "exec yes")
        let r4 = await gwsRun(streaming, timeout: 1)
        check("G6b an endlessly writing child still times out (\(secs(r4.elapsed)) s)",
              r4.value?.failureDetail == "timed out after 1s" && r4.elapsed < promptBound, r4.value?.failureDetail ?? "hung")
        check("G6c both timed-out children were reaped",
              DiffPipeSelftest.childPids(named: ["sleep", "yes", "gws-stuck", "gws-yes"]).isEmpty, "")
    }

    // MARK: - S1-S5: ToolExecutor.runShortcutProcess

    typealias ShortcutResult = ToolExecutor.ShortcutProcessResult

    final class CallNote: @unchecked Sendable {
        private let lock = NSLock()
        private var value = ""
        func set(_ v: String) { lock.lock(); value = v; lock.unlock() }
        var get: String { lock.lock(); defer { lock.unlock() }; return value }
    }

    static func shortcutRun(_ exe: String, _ args: [String] = [], timeout: Double = 10,
                            flag: CallNote? = nil) async -> (value: ShortcutResult?, elapsed: TimeInterval) {
        await bounded { () -> ShortcutResult in
            await ToolExecutor.runShortcutProcess(
                executable: exe, arguments: args, timeoutSeconds: timeout, register: { _ in },
                onTimeout: { flag?.set("timeout") }, onLaunchFailure: { flag?.set("launch: \($0.localizedDescription)") })
        }
    }

    static func shortcutsLargeOutput(_ check: Check, dir: URL) async {
        let big = script(dir, "sc-1mb", flood(megabyte, "s"))
        let r1 = await shortcutRun(big)
        check("S1 1 MB of stdout comes back complete, exit 0 (\(secs(r1.elapsed)) s)",
              r1.value?.exitCode == 0 && r1.value?.outputProblem == nil
              && r1.value?.stdoutData == Data(repeating: UInt8(ascii: "s"), count: megabyte)
              && r1.elapsed < promptBound, "exit \(r1.value?.exitCode ?? -99) \(r1.value?.stdoutData.count ?? -1) bytes")
        let piped = "\(flood(100_000, "p")) | /bin/cat"
        let r2 = await shortcutRun("/bin/sh", ["-c", piped])
        check("S2 the `| /bin/cat` fallback shape: ~100 KB complete (\(secs(r2.elapsed)) s)",
              r2.value?.exitCode == 0 && r2.value?.stdoutData.count == 100_000 && r2.elapsed < promptBound,
              "\(r2.value?.stdoutData.count ?? -1) bytes")
        let noisy = script(dir, "sc-noisy", flood(megabyte, "w", toStderr: true) + "\nprintf 'done'")
        let r3 = await shortcutRun(noisy)
        check("S3 1 MB on stderr cannot block; stdout and stderr both complete (\(secs(r3.elapsed)) s)",
              r3.value?.stdoutData == Data("done".utf8) && r3.value?.stderrData.count == megabyte && r3.elapsed < promptBound,
              "\(r3.value?.stderrData.count ?? -1) stderr bytes")
    }

    static func shortcutsErrorsAndTimeout(_ check: Check, dir: URL) async {
        let small = script(dir, "sc-small", "printf 'hello\\n'\nprintf 'warn' 1>&2\nexit 4")
        let r1 = await shortcutRun(small)
        check("S4a small output and exit status byte-identical",
              r1.value?.exitCode == 4 && r1.value?.stdoutData == Data("hello\n".utf8) && r1.value?.stderrData == Data("warn".utf8), "")
        let flag = CallNote()
        let r2 = await shortcutRun(dir.appendingPathComponent("does-not-exist").path, flag: flag)
        check("S4b launch failure: (-1, no stdout, the error text)",
              r2.value?.exitCode == -1 && r2.value?.stdoutData.isEmpty == true && r2.value?.stderrData.isEmpty == false
              && flag.get.hasPrefix("launch: "), flag.get)
        // S5 is macOS only. The Shortcuts tool exists only on macOS
        // (shortcutsEnabled is false on Linux), and its timeout sends SIGTERM
        // alone, unchanged since 0.2.45. In the Linux CI container that
        // SIGTERM did not end the stuck child within the bound, so the row
        // would test a path Linux never runs and leave a sleeper for X1.
        #if os(macOS)
        let stuck = script(dir, "sc-stuck", "exec sleep 30")
        let timeoutFlag = CallNote()
        let r3 = await shortcutRun(stuck, timeout: 0.5, flag: timeoutFlag)
        check("S5a the timeout still terminates a stuck run (\(secs(r3.elapsed)) s)",
              r3.value != nil && r3.value?.exitCode != 0 && timeoutFlag.get == "timeout" && r3.elapsed < promptBound,
              "exit \(r3.value?.exitCode ?? -99) flag \(timeoutFlag.get)")
        check("S5b the timed-out run was reaped", DiffPipeSelftest.childPids(named: ["sleep", "sc-stuck"]).isEmpty, "")
        #endif
    }

}
