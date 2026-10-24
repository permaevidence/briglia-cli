import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Shared subprocess and download helpers (moved verbatim from the removed
/// GoogleWorkspaceService, 2026-10-24: gws was dropped, these never were
/// gws-specific). Used by the toolchain, Node and AgentMail installers,
/// setup and the process-pipe selftests.
enum ProcessRunner {
    /// stdout on success; on failure, a one-line human-readable cause (launch
    /// error, timeout, or exit code + stderr head) so callers can surface WHY
    /// instead of a bare nil. stderrHead is captured even on exit 0: gws has
    /// been observed exiting 0 with empty stdout, where stderr held the only
    /// evidence of what went wrong.
    struct ProcessRunResult: Sendable {
        let stdout: String?
        let failureDetail: String?
        let stderrHead: String?
    }

    static func runProcessAsync(executable: String, args: [String], timeoutSeconds: Int) async -> ProcessRunResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let out = runBlockingProcess(executable: executable, args: args, timeoutSeconds: timeoutSeconds)
                continuation.resume(returning: out)
            }
        }
    }

    static func runBlockingProcess(executable: String, args: [String], timeoutSeconds: Int) -> ProcessRunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args

        // Augment PATH so `gws` can find its own helpers (some versions invoke
        // git/etc.) and so `#!/usr/bin/env node` shims resolve ~/.local/bin.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = BashTools.augmentedPath(env["PATH"])
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            print("[ProcessRunner] failed to launch \(executable): \(error)")
            return ProcessRunResult(stdout: nil, failureDetail: "failed to launch \(executable): \(error.localizedDescription)", stderrHead: nil)
        }
        // Drain both pipes while the child runs: reading them only after exit
        // stalled any child writing > 64 KB (large gws JSON, brew/pip logs)
        // until the timeout, which then reported "timed out".
        let capture = ProcessOutputCapture(stdout: outPipe, stderr: errPipe)
        capture.start()

        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            _ = capture.finish(within: 2)
            print("[ProcessRunner] \(executable) timed out after \(timeoutSeconds)s")
            return ProcessRunResult(stdout: nil, failureDetail: "timed out after \(timeoutSeconds)s", stderrHead: nil)
        }

        process.waitUntilExit()
        let output = capture.finish(within: 2)
        let stdout = String(data: output.stdout, encoding: .utf8) ?? ""
        let stderr = ProcessOutputCapture.text(output.stderr)
        let head = stderr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)
        let stderrHead = head.isEmpty ? nil : String(head)
        guard process.terminationStatus == 0 else {
            print("[ProcessRunner] \(executable) exit=\(process.terminationStatus); stderr head: \(head)")
            return ProcessRunResult(stdout: nil, failureDetail: "exit \(process.terminationStatus)\(head.isEmpty ? "" : ": \(head)")", stderrHead: stderrHead)
        }
        // Callers parse this stdout (gws JSON, versions): never hand over a
        // cut or unfinished capture as if it were the whole output.
        if let problem = output.stdoutProblem {
            print("[ProcessRunner] \(executable) output \(problem)")
            return ProcessRunResult(stdout: nil, failureDetail: "output \(problem)", stderrHead: stderrHead)
        }
        return ProcessRunResult(stdout: stdout, failureDetail: nil, stderrHead: stderrHead)
    }

    /// Streams a download while reporting coarse progress through `progress`
    /// ("<label>… 45%", or "<label>… 12 MB" when the server sends no
    /// Content-Length). URLSession.data(from:) gives no feedback, and a
    /// 50 MB pull on slow Wi-Fi looks frozen without one.
    static func downloadReportingProgress(
        from url: URL,
        label: String,
        progress: (@Sendable (String) -> Void)?
    ) async throws -> Data {
        #if !canImport(Darwin)
        // corelibs FoundationNetworking has no URLSession.bytes — download in
        // one shot with a start/end notice instead of incremental progress.
        progress?("\(label)…")
        let (blob, resp) = try await URLSession.shared.data(from: url)
        if let code = (resp as? HTTPURLResponse)?.statusCode, code != 200 {
            throw NSError(domain: "ProcessRunner.download", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(code)"])
        }
        progress?("\(label)… \(blob.count / 1_048_576) MB")
        return blob
        #else
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        if let code = (response as? HTTPURLResponse)?.statusCode, code != 200 {
            throw NSError(domain: "ProcessRunner.download", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(code)"])
        }
        let expected = response.expectedContentLength // -1 when unknown
        var data = Data()
        if expected > 0 { data.reserveCapacity(Int(expected)) }
        var lastStep = -1
        for try await byte in bytes {
            data.append(byte)
            guard let progress else { continue }
            if expected > 0 {
                // Report in 5% increments.
                let step = Int((Double(data.count) / Double(expected)) * 20)
                if step != lastStep {
                    lastStep = step
                    progress("\(label)… \(min(step * 5, 100))%")
                }
            } else {
                // No Content-Length: report every 5 MB.
                let step = data.count / (5 * 1_048_576)
                if step != lastStep {
                    lastStep = step
                    progress("\(label)… \(data.count / 1_048_576) MB")
                }
            }
        }
        return data
        #endif
    }
}
