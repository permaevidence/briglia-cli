import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Hidden battery for server-to-client requests on Briglia's MCP client
/// (v0.2.55). Before: the client declared `roots` and `sampling` without
/// implementing them and silently dropped every server request, so the pinned
/// Playwright MCP waited out the SDK's 60 s timeout on `roots/list` before the
/// first browser call of every Browse run.
///
///   §1 the declared capabilities and the reply table (pure).
///   §2 a fake stdio server sends ping, roots/list, sampling/createMessage,
///      elicitation/create and an unknown method (numeric and string ids)
///      plus a notification during a tools/call: every request is answered,
///      promptly, with the right id; the notification gets nothing.
///   §3 Playwright-shaped servers: one asks `roots/list` only when the client
///      declared roots (the real Playwright logic), one asks it regardless.
///      Both must finish their first tool call in well under their 20 s wait.
///   §4 a server that floods requests and stops reading its stdin (Codex
///      0.2.55 R1): timeouts and shutdown stay responsive, the stall limit
///      and byte cap fail the transport, ordering and framing hold.
///
/// `--playwright-cli <cli.js>` instead times the first two
/// `browser_navigate` calls against a REAL installed @playwright/mcp
/// (headless, isolated profile, output under a temp dir) and prints the
/// numbers; it fails when the first call takes 20 s or more.
///
/// Spawns only under an isolated XDG root; the real config is never touched.
struct MCPServerRequestSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__mcp-server-request-selftest",
        abstract: "Internal: verify server-to-client MCP requests are answered, never left waiting.",
        shouldDisplay: false
    )

    @Option(name: .customLong("playwright-cli"), help: .hidden)
    var playwrightCli: String?

    /// With `--playwright-cli`: keep a persistent (temp-dir) profile and
    /// print its directory name, which encodes the workspace Playwright chose.
    @Flag(name: .customLong("persistent-profile"), help: .hidden)
    var persistentProfile = false

    /// A first call slower than this is the old roots/list wait (60 s), not
    /// a browser start.
    static let firstCallCeiling: TimeInterval = 20

    func run() async throws {
        // Like the chat/daemon entry points: line-buffered stdout and SIGPIPE
        // ignored (a broken server pipe is an EPIPE error, not a kill).
        AdaCLI.prepareIO()
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("briglia-mcp-server-request-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        setenv("XDG_CONFIG_HOME", tempRoot.path, 1)
        setenv("XDG_DATA_HOME", tempRoot.path, 1)
        setenv("TMPDIR", tempRoot.path + "/", 1)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "✔" : "✖") \(label)\(ok || detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }

        if let cli = playwrightCli {
            try await Self.runRealPlaywright(cli: cli, persistentProfile: persistentProfile, tempRoot: tempRoot, check: check)
        } else {
            Self.runReplyTable(check: check)
            try await Self.runServerRequests(tempRoot: tempRoot, check: check)
            try await Self.runPlaywrightShaped(tempRoot: tempRoot, check: check)
            try await Self.runBackpressure(tempRoot: tempRoot, check: check)
            try await Self.runRetention(tempRoot: tempRoot, check: check)
        }
        print(failures == 0 ? "\nall checks passed" : "\n\(failures) check(s) FAILED")
        if failures > 0 { throw ExitCode(1) }
    }

    // MARK: - §1 Capabilities and reply table

    static func runReplyTable(check: (String, Bool, String) -> Void) {
        print("— §1 declared capabilities and reply table")
        let caps = MCPClient.clientCapabilities
        check("1.1 client declares neither roots nor sampling",
              caps["roots"] == nil && caps["sampling"] == nil, "\(caps)")
        let ping = MCPClient.replyToServerRequest(method: "ping", id: 7)
        check("1.2 ping → empty result, same id, no error",
              (ping["id"] as? Int) == 7 && (ping["result"] as? [String: Any])?.isEmpty == true && ping["error"] == nil,
              "\(ping)")
        for method in ["roots/list", "sampling/createMessage", "elicitation/create", "x/unknown"] {
            let reply = MCPClient.replyToServerRequest(method: method, id: "s-\(method)")
            check("1.3 \(method) → -32601 with the string id echoed",
                  errorCode(reply) == -32601 && (reply["id"] as? String) == "s-\(method)" && reply["result"] == nil,
                  "\(reply)")
        }
        let encoded = (try? MCPFraming.encode(MCPClient.replyToServerRequest(method: "roots/list", id: 3)))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        check("1.4 reply frames as one JSON-RPC 2.0 line",
              encoded.hasSuffix("\n") && encoded.contains("\"jsonrpc\":\"2.0\"") && encoded.filter { $0 == "\n" }.count == 1,
              encoded)
    }

    static func errorCode(_ reply: [String: Any]) -> Int? {
        (reply["error"] as? [String: Any])?["code"] as? Int
    }

    // MARK: - §2 Every server request answered

    static func runServerRequests(tempRoot: URL, check: (String, Bool, String) -> Void) async throws {
        print("— §2 server-to-client requests during a tool call")
        let client = try await startFake(tempRoot: tempRoot, name: "probe", mode: "probe")
        defer { Task { await client.shutdown() } }
        let started = Date()
        let result = try await client.callTool(name: "probe", arguments: [:])
        let elapsed = Date().timeIntervalSince(started)
        await client.shutdown()
        guard let report = decode(result.text) else {
            check("2.0 probe report decodes", false, result.text); return
        }
        let replies = report["replies"] as? [String: [String: Any]] ?? [:]
        check("2.1 the tool call returned promptly (\(String(format: "%.2f", elapsed)) s)", elapsed < 5, "")
        check("2.2 server saw no roots/sampling capability",
              (report["caps"] as? [String: Any])?["roots"] == nil && (report["caps"] as? [String: Any])?["sampling"] == nil,
              "\(report["caps"] ?? "nil")")
        check("2.3 every request answered, each exactly once, ids echoed",
              Set(replies.keys) == ["p-1", "9001", "9002", "9003", "u-x"] && (report["duplicates"] as? Int) == 0,
              "\(replies.keys.sorted()) dup=\(report["duplicates"] ?? "nil")")
        check("2.4 ping answered with an empty result",
              (replies["p-1"]?["result"] as? [String: Any])?.isEmpty == true && replies["p-1"]?["error"] == nil,
              "\(replies["p-1"] ?? [:])")
        for id in ["9001", "9002", "9003", "u-x"] {
            check("2.5 request \(id) answered -32601", errorCode(replies[id] ?? [:]) == -32601, "\(replies[id] ?? [:])")
        }
        check("2.6 the notification got no reply", (report["stray"] as? Int) == 0, "stray=\(report["stray"] ?? "nil")")
    }

    // MARK: - §3 Playwright-shaped first call

    static func runPlaywrightShaped(tempRoot: URL, check: (String, Bool, String) -> Void) async throws {
        print("— §3 Playwright-shaped first tool call")
        for mode in ["roots-if-declared", "roots-always"] {
            let client = try await startFake(tempRoot: tempRoot, name: mode, mode: mode)
            let started = Date()
            let result = try await client.callTool(name: "probe", arguments: [:])
            let elapsed = Date().timeIntervalSince(started)
            await client.shutdown()
            let report = decode(result.text) ?? [:]
            check("3.\(mode) first call in \(String(format: "%.2f", elapsed)) s (server waits up to 20 s for roots/list)",
                  elapsed < 5 && (report["waited_out"] as? Bool) == false, result.text)
        }
    }

    // MARK: - Fake server plumbing

    static func startFake(tempRoot: URL, name: String, mode: String) async throws -> MCPClient {
        let script = tempRoot.appendingPathComponent("fake_requesting_mcp.py")
        if !FileManager.default.fileExists(atPath: script.path) {
            try fakeServerSource.write(to: script, atomically: true, encoding: .utf8)
        }
        let client = MCPClient(
            config: MCPServerConfig(name: name, command: pythonPath, arguments: [script.path, mode]),
            resolvedEnvironment: ProcessInfo.processInfo.environment)
        try await client.start()
        try await client.initialize(timeout: 10)
        return client
    }

    static var pythonPath: String {
        ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/bin/python3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "python3"
    }

    static func decode(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Stdio MCP server. `probe`: on tools/call sends five requests and one
    /// notification, collects replies for up to 8 s, returns them.
    /// `roots-if-declared`: asks roots/list only when the client declared
    /// roots (Playwright's rule) and waits up to 20 s for any answer.
    /// `roots-always`: asks it regardless of the declaration.
    static let fakeServerSource = """
    import sys, json, time, select
    mode = sys.argv[1]
    caps = {}
    buf = b""
    def send(obj):
        sys.stdout.write(json.dumps(obj) + "\\n"); sys.stdout.flush()
    def read_line(deadline):
        global buf
        while b"\\n" not in buf:
            left = deadline - time.time()
            if left <= 0:
                return None
            r, _, _ = select.select([sys.stdin.buffer], [], [], left)
            if not r:
                return None
            chunk = sys.stdin.buffer.raw.read(65536) if hasattr(sys.stdin.buffer, "raw") else sys.stdin.buffer.read1(65536)
            if not chunk:
                sys.exit(0)
            buf += chunk
        line, buf = buf.split(b"\\n", 1)
        return line
    def collect(ids, seconds):
        got, dup, stray = {}, 0, 0
        deadline = time.time() + seconds
        while time.time() < deadline and len(got) < len(ids):
            line = read_line(deadline)
            if line is None:
                break
            if not line.strip():
                continue
            msg = json.loads(line)
            key = str(msg.get("id"))
            if "method" in msg:
                continue
            if key in got:
                dup += 1
            elif key in ids:
                got[key] = msg
            else:
                stray += 1
        # Linger briefly: a reply to the notification (or a duplicate) would show up here.
        end = time.time() + 0.3
        while True:
            line = read_line(end)
            if line is None:
                break
            if line.strip():
                msg = json.loads(line)
                if "method" not in msg:
                    if str(msg.get("id")) in got: dup += 1
                    else: stray += 1
        return got, dup, stray
    def tool_call(mid):
        if mode == "probe":
            send({"jsonrpc": "2.0", "id": "p-1", "method": "ping"})
            send({"jsonrpc": "2.0", "id": 9001, "method": "roots/list"})
            send({"jsonrpc": "2.0", "id": 9002, "method": "sampling/createMessage", "params": {"messages": [], "maxTokens": 1}})
            send({"jsonrpc": "2.0", "id": 9003, "method": "elicitation/create", "params": {"message": "x", "requestedSchema": {}}})
            send({"jsonrpc": "2.0", "method": "notifications/progress", "params": {"progressToken": 1, "progress": 1}})
            send({"jsonrpc": "2.0", "id": "u-x", "method": "custom/unknown"})
            got, dup, stray = collect({"p-1", "9001", "9002", "9003", "u-x"}, 8)
            report = {"caps": caps, "replies": got, "duplicates": dup, "stray": stray}
        else:
            ask = mode == "roots-always" or "roots" in caps
            waited_out = False
            if ask:
                send({"jsonrpc": "2.0", "id": 77, "method": "roots/list"})
                got, _, _ = collect({"77"}, 20)
                waited_out = "77" not in got
            report = {"caps": caps, "asked": ask, "waited_out": waited_out}
        send({"jsonrpc": "2.0", "id": mid, "result": {"content": [{"type": "text", "text": json.dumps(report)}]}})
    while True:
        line = read_line(time.time() + 3600)
        if line is None:
            continue
        if not line.strip():
            continue
        msg = json.loads(line)
        if "id" not in msg or "method" not in msg:
            continue
        m = msg["method"]
        if m == "initialize":
            caps = msg.get("params", {}).get("capabilities", {})
            send({"jsonrpc": "2.0", "id": msg["id"], "result": {"protocolVersion": "2024-11-05", "capabilities": {"tools": {}}, "serverInfo": {"name": mode, "version": "0"}}})
        elif m == "tools/list":
            send({"jsonrpc": "2.0", "id": msg["id"], "result": {"tools": [{"name": "probe", "description": "probe", "inputSchema": {"type": "object", "properties": {}}}]}})
        elif m == "tools/call":
            tool_call(msg["id"])
        else:
            send({"jsonrpc": "2.0", "id": msg["id"], "result": {}})
    """
}
