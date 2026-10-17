import Foundation

/// §4 of `__mcp-server-request-selftest` (Codex 0.2.55 R1): a server that
/// floods requests and stops reading its stdin must never block the client.
/// Real pipes, real `MCPClient`; the python server keeps stdin OPEN but
/// unread for `hold` seconds, then exits.
extension MCPServerRequestSelftest {

    static let floodCount = 3000
    static let holdSeconds = 10

    static func runBackpressure(tempRoot: URL, check: (String, Bool, String) -> Void) async throws {
        print("— §4 a server that stops reading its input")
        let threadsBefore = MCPOutboundPipe.liveWriterThreads
        try await backpressureAnsweredList(tempRoot: tempRoot, check: check)
        try await backpressureSilentList(tempRoot: tempRoot, check: check)
        try await backpressureStall(tempRoot: tempRoot, check: check)
        try await backpressureByteCap(tempRoot: tempRoot, check: check)
        try await backpressureOrdering(tempRoot: tempRoot, check: check)
        let settled = await waitFor(seconds: 3) { MCPOutboundPipe.liveWriterThreads <= threadsBefore }
        check("4.9 no writer thread stranded after every client shut down", settled,
              "live writers \(MCPOutboundPipe.liveWriterThreads), before \(threadsBefore)")
    }

    static func floodClient(tempRoot: URL, mode: String,
                            limits: MCPOutboundPipe.Limits = .standard) async throws -> MCPClient {
        let script = tempRoot.appendingPathComponent("flood_mcp.py")
        if !FileManager.default.fileExists(atPath: script.path) {
            try floodServerSource.write(to: script, atomically: true, encoding: .utf8)
        }
        let client = MCPClient(
            config: MCPServerConfig(name: mode, command: pythonPath,
                                    arguments: [script.path, mode, "\(floodCount)", "\(holdSeconds)"]),
            resolvedEnvironment: ProcessInfo.processInfo.environment, outboundLimits: limits)
        try await client.start()
        return client
    }

    /// Codex's reproduction shape: pings, then the tools/list result, then
    /// stdin left unread. initialize must succeed; a shutdown with a 1 s
    /// budget requested meanwhile must return within it.
    static func backpressureAnsweredList(tempRoot: URL, check: (String, Bool, String) -> Void) async throws {
        let client = try await floodClient(tempRoot: tempRoot, mode: "flood-answer")
        let shutdownTime = shutdownDuringHold(client)
        let t0 = Date()
        var initError = ""
        do { try await client.initialize(timeout: 1) } catch { initError = "\(error)" }
        let initTime = Date().timeIntervalSince(t0)
        check("4.1 initialize decodes the tool list behind \(floodCount) pings (\(fmt(initTime)) s)",
              initError.isEmpty && initTime < 3, initError)
        let shut = await shutdownTime.value
        check("4.2 shutdown(1 s budget) requested while the server is not reading returns in \(fmt(shut)) s",
              shut < 2.5, "")
        await client.shutdown()
    }

    /// Request `shutdown(deadline: 1 s)` 1.5 s after the client started
    /// (the server is then holding its stdin unread) and time it.
    static func shutdownDuringHold(_ client: MCPClient) -> Task<TimeInterval, Never> {
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let t = Date()
            await client.shutdown(deadline: .after(seconds: 1))
            return Date().timeIntervalSince(t)
        }
    }

    /// Pings, no answer, stdin unread: the 1 s watchdog must still fire.
    static func backpressureSilentList(tempRoot: URL, check: (String, Bool, String) -> Void) async throws {
        let client = try await floodClient(tempRoot: tempRoot, mode: "flood-silent")
        let shutdownTime = shutdownDuringHold(client)
        let t0 = Date()
        var timedOut = false
        do { try await client.initialize(timeout: 1) } catch MCPClientError.timedOut { timedOut = true } catch {}
        let elapsed = Date().timeIntervalSince(t0)
        check("4.3 the 1 s request timeout fires on time (\(fmt(elapsed)) s)", timedOut && elapsed < 3, "")
        let shut = await shutdownTime.value
        check("4.4 shutdown(1 s budget) requested meanwhile returns in \(fmt(shut)) s", shut < 2.5, "")
        await client.shutdown()
    }

    /// Stall limit 1 s: a parked call fails with writeFailed and the server
    /// is ended, without waiting for its own timeout.
    static func backpressureStall(tempRoot: URL, check: (String, Bool, String) -> Void) async throws {
        let limits = MCPOutboundPipe.Limits(maxQueuedBytes: 16 << 20, stallSeconds: 1, pollMillis: 50)
        let client = try await floodClient(tempRoot: tempRoot, mode: "flood-call", limits: limits)
        try await client.initialize(timeout: 5)
        let t0 = Date()
        var outcome = "returned"
        do { _ = try await client.callTool(name: "probe", arguments: [:]) }
        catch MCPClientError.writeFailed(let reason) { outcome = "writeFailed: \(reason)" }
        catch { outcome = "\(error)" }
        let elapsed = Date().timeIntervalSince(t0)
        check("4.5 stalled input pipe fails the parked call (\(fmt(elapsed)) s)",
              outcome.contains("has not read its input") && elapsed < 5, outcome)
        let ended = await waitFor(seconds: 4) { !(await client.isAlive) }
        check("4.6 the stalled server is ended (client no longer alive)", ended, "")
        await client.shutdown()
    }

    /// Byte cap 16 KiB: the queue overflows long before the stall limit.
    static func backpressureByteCap(tempRoot: URL, check: (String, Bool, String) -> Void) async throws {
        let limits = MCPOutboundPipe.Limits(maxQueuedBytes: 16 << 10, stallSeconds: 60, pollMillis: 50)
        let client = try await floodClient(tempRoot: tempRoot, mode: "flood-call", limits: limits)
        try await client.initialize(timeout: 5)
        let t0 = Date()
        var outcome = "returned"
        do { _ = try await client.callTool(name: "probe", arguments: [:]) }
        catch MCPClientError.writeFailed(let reason) { outcome = "writeFailed: \(reason)" }
        catch { outcome = "\(error)" }
        check("4.7 queue byte cap fails the transport (\(fmt(Date().timeIntervalSince(t0))) s)",
              outcome.contains("bytes queued") && Date().timeIntervalSince(t0) < 5, outcome)
        await client.shutdown()
    }

    /// A slow (not stalled) reader: every reply arrives exactly once, in
    /// request order, and a 300 KB request queued among them arrives whole.
    static func backpressureOrdering(tempRoot: URL, check: (String, Bool, String) -> Void) async throws {
        let client = try await floodClient(tempRoot: tempRoot, mode: "slow-reader")
        try await client.initialize(timeout: 5)
        async let flood = client.callTool(name: "probe", arguments: [:])
        try? await Task.sleep(nanoseconds: 300_000_000)
        let big = String(repeating: "x", count: 300_000)
        let bigResult = try? await client.callTool(name: "big", arguments: ["blob": big])
        let report = decode((try? await flood)?.text ?? "") ?? [:]
        await client.shutdown()
        check("4.8 slow reader: \(floodCount) replies once each, in order, frames intact, big request whole",
              (report["ok"] as? Bool) == true && bigResult?.text == "big:300000", "\(report) big=\(bigResult?.text ?? "nil")")
    }

    static func waitFor(seconds: Double, _ condition: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return await condition()
    }

    static func fmt(_ t: TimeInterval) -> String { String(format: "%.2f", t) }

    /// Modes: flood-answer (pings + tools/list result, then unread stdin),
    /// flood-silent (pings, no result, unread stdin), flood-call (normal
    /// handshake; on tools/call pings and unread stdin), slow-reader (on
    /// the first tools/call pings, pauses 1 s, then reads and verifies every
    /// reply; answers a later "big" call with its blob length).
    static let floodServerSource = """
    import sys, json, time, select
    mode, count, hold = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    buf = b""
    def send(o):
        sys.stdout.write(json.dumps(o) + "\\n"); sys.stdout.flush()
    def line(deadline):
        global buf
        while b"\\n" not in buf:
            left = deadline - time.time()
            if left <= 0: return None
            r, _, _ = select.select([sys.stdin.buffer], [], [], left)
            if not r: return None
            c = sys.stdin.buffer.raw.read(1 << 20)
            if not c: sys.exit(0)
            buf += c
        l, buf = buf.split(b"\\n", 1)
        return l
    def flood():
        for n in range(count):
            send({"jsonrpc": "2.0", "id": "s-%d" % n, "method": "ping"})
    def hold_unread():
        time.sleep(hold); sys.exit(0)
    pending_big = None
    while True:
        l = line(time.time() + 3600)
        if l is None or not l.strip(): continue
        m = json.loads(l)
        meth = m.get("method")
        if meth is None: continue
        if meth == "initialize":
            send({"jsonrpc": "2.0", "id": m["id"], "result": {"protocolVersion": "2024-11-05", "capabilities": {"tools": {}}, "serverInfo": {"name": mode, "version": "0"}}})
        elif meth == "notifications/initialized":
            continue
        elif meth == "tools/list":
            if mode in ("flood-answer", "flood-silent"):
                flood()
                if mode == "flood-answer":
                    send({"jsonrpc": "2.0", "id": m["id"], "result": {"tools": []}})
                hold_unread()
            send({"jsonrpc": "2.0", "id": m["id"], "result": {"tools": [{"name": "probe", "description": "p", "inputSchema": {"type": "object", "properties": {}}}, {"name": "big", "description": "b", "inputSchema": {"type": "object", "properties": {}}}]}})
        elif meth == "tools/call" and mode == "flood-call":
            flood(); hold_unread()
        elif meth == "tools/call" and m["params"]["name"] == "probe":
            flood()
            time.sleep(1)
            want = ["s-%d" % n for n in range(count)]
            seen, bad = [], 0
            deadline = time.time() + 30
            while len(seen) < count and time.time() < deadline:
                r = line(deadline)
                if r is None: break
                try: o = json.loads(r)
                except Exception: bad += 1; continue
                if o.get("method") == "tools/call" and o["params"]["name"] == "big":
                    pending_big = o; continue
                if "method" in o: continue
                seen.append(o.get("id"))
                if o.get("result") != {}: bad += 1
            ok = seen == want and bad == 0
            send({"jsonrpc": "2.0", "id": m["id"], "result": {"content": [{"type": "text", "text": json.dumps({"ok": ok, "replies": len(seen), "bad": bad})}]}})
            if pending_big is not None:
                n = len(pending_big["params"]["arguments"]["blob"])
                send({"jsonrpc": "2.0", "id": pending_big["id"], "result": {"content": [{"type": "text", "text": "big:%d" % n}]}})
        elif meth == "tools/call":
            n = len(m["params"]["arguments"].get("blob", ""))
            send({"jsonrpc": "2.0", "id": m["id"], "result": {"content": [{"type": "text", "text": "big:%d" % n}]}})
        elif "id" in m:
            send({"jsonrpc": "2.0", "id": m["id"], "result": {}})
    """
}
