import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// The real-Playwright half of `__mcp-server-request-selftest`, also used by
/// `__playwright-selftest --live`: time the first browser calls of a fresh
/// server, the way a Browse run makes them.
extension MCPServerRequestSelftest {

    struct FirstCallTiming {
        let initialize: TimeInterval
        let first: TimeInterval
        let second: TimeInterval
        let firstSucceeded: Bool
        let firstText: String
    }

    /// Start the real @playwright/mcp at `cli` through `MCPClient` (the
    /// production client, so the production `initialize`), then call
    /// `browser_navigate` to about:blank twice. Headless with an in-memory
    /// profile and output under `outputDir`: nothing is written to the real
    /// browser profile or the home directory. A missing browser still
    /// returns an error quickly, which is enough to time the roots wait.
    static func timeFirstBrowserCalls(cli: String, nodeDirectory: String?, outputDir: URL,
                                      persistentProfile: Bool = false) async throws -> FirstCallTiming {
        var env = ProcessInfo.processInfo.environment
        if let nodeDirectory { env["PATH"] = nodeDirectory + ":" + (env["PATH"] ?? "/usr/bin:/bin") }
        env["PWMCP_PROFILES_DIR_FOR_TEST"] = outputDir.appendingPathComponent("profiles").path
        // Playwright puts a Unix socket under the temp directory and refuses
        // paths over ~104 bytes; the selftest TMPDIR is far longer.
        var template = Array("/tmp/brpw.XXXXXX".utf8CString)
        let shortTmp: String? = template.withUnsafeMutableBufferPointer { buf in mkdtemp(buf.baseAddress!).map { String(cString: $0) } }
        if let shortTmp { env["TMPDIR"] = shortTmp + "/" }
        defer { if let shortTmp { try? FileManager.default.removeItem(atPath: shortTmp) } }
        let node = nodeDirectory.map { $0 + "/node" } ?? "node"
        let client = MCPClient(
            config: MCPServerConfig(name: "playwright", command: node,
                                    arguments: [cli, "--headless"] + (persistentProfile ? [] : ["--isolated"]) + ["--output-dir", outputDir.path]),
            resolvedEnvironment: env)
        try await client.start()
        let t0 = Date()
        do {
            try await client.initialize(timeout: 60)
        } catch {
            await client.shutdown(); throw error
        }
        let initialize = Date().timeIntervalSince(t0)
        let args: [String: Any] = ["url": "about:blank"]
        let t1 = Date()
        let first = try? await client.callTool(name: "browser_navigate", arguments: args)
        let firstTime = Date().timeIntervalSince(t1)
        let t2 = Date()
        _ = try? await client.callTool(name: "browser_navigate", arguments: args)
        let secondTime = Date().timeIntervalSince(t2)
        _ = try? await client.callTool(name: "browser_close", arguments: [:])
        await client.shutdown()
        let text = first?.text ?? "(call threw)"
        let failed = first == nil || text.hasPrefix("{\"error\"")
        return FirstCallTiming(initialize: initialize, first: firstTime, second: secondTime,
                               firstSucceeded: !failed, firstText: String(text.prefix(300)))
    }

    static func runRealPlaywright(cli: String, persistentProfile: Bool, tempRoot: URL,
                                  check: (String, Bool, String) -> Void) async throws {
        print("— real @playwright/mcp at \(cli)")
        let nodeDir = ManagedPlaywright.resolveNodeDirectory().directory
        let outputDir = tempRoot.appendingPathComponent("pw-output", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let timing = try await timeFirstBrowserCalls(cli: cli, nodeDirectory: nodeDir, outputDir: outputDir,
                                                     persistentProfile: persistentProfile)
        if persistentProfile {
            // The profile directory is named after the workspace Playwright
            // derived (mcp-<browser>-<sha256(workspace) prefix>): proof of
            // which working directory it settled on.
            let names = (try? FileManager.default.contentsOfDirectory(atPath: outputDir.appendingPathComponent("profiles").path)) ?? []
            print("PROFILE dirs=\(names.sorted())")
        }
        print(String(format: "TIMING initialize=%.2fs first_navigate=%.2fs second_navigate=%.2fs first_ok=%@",
                     timing.initialize, timing.first, timing.second, timing.firstSucceeded ? "yes" : "no"))
        if !timing.firstSucceeded { print("first call: \(timing.firstText)") }
        check("real.1 first browser_navigate in under \(Int(firstCallCeiling)) s (\(String(format: "%.2f", timing.first)) s)",
              timing.first < firstCallCeiling, timing.firstText)
    }
}
