import ArgumentParser
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#endif

/// Hidden deterministic test of the companion-app chat socket.
/// Pins (a) the pure message-event rendering rules (what is and is not part
/// of the visible conversation), (b) the live wire: hello + history
/// snapshot, ping, shared command routing, honest nacks, malformed-line
/// resilience, (c) the security posture: 0600 socket mode and stale-socket
/// rebind, and (d) privacy mode's withhold-and-replay contract on the wire.
/// Fully isolated: XDG roots point at a SHORT temp directory (sockaddr_un
/// caps the path length) before anything touches StoragePaths — same
/// freeze-at-first-access ordering contract as the other selftests.
struct AppChatSocketSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__chat-socket-selftest",
        abstract: "Internal: verify the companion-app chat socket server.",
        shouldDisplay: false
    )

    func run() async throws {
        // The chat/daemon entry points ignore SIGPIPE in prepareIO(); this
        // subcommand must too — the test deliberately churns connections, and
        // a server write racing a just-closed client otherwise KILLS the
        // selftest with no output (seen as CI "FAIL chat-socket-selftest"
        // with an empty log, exit -13).
        AdaCLI.prepareIO()

        // /tmp, not FileManager.temporaryDirectory: macOS per-user temp roots
        // are long enough to overflow sockaddr_un's 104-byte path cap.
        let tempRoot = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("ada-cs-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        setenv("XDG_CONFIG_HOME", tempRoot.path, 1)
        setenv("XDG_DATA_HOME", tempRoot.path, 1)
        setenv("TMPDIR", tempRoot.path + "/", 1)
        FileDescriptionsStore._testStoreURL =
            tempRoot.appendingPathComponent("test-file-descriptions.json")

        let watchdog = Task.detached {
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            if !Task.isCancelled {
                print("WATCHDOG: chat-socket selftest exceeded 120s — hung; aborting")
                Foundation.exit(3)
            }
        }
        defer { watchdog.cancel() }

        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "✔" : "✖") \(label)\(ok || detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }

        // ------------------------------------------------------------------
        // 1. Pure rendering rules
        // ------------------------------------------------------------------
        do {
            let emptyAssistant = Message(role: .assistant, content: "   ")
            check("render: empty assistant message is not an event",
                  AppChatSocketServer.renderMessageEvent(emptyAssistant, queued: false) == nil)

            let reply = Message(role: .assistant, content: "Ciao!")
            let replyEvent = AppChatSocketServer.renderMessageEvent(reply, queued: false)
            check("render: assistant reply carries id/role/text/ts",
                  replyEvent?["role"] as? String == "assistant"
                  && replyEvent?["text"] as? String == "Ciao!"
                  && replyEvent?["id"] as? String == reply.id.uuidString
                  && replyEvent?["ts"] is Double
                  && replyEvent?["queued"] as? Bool == false)

            let attachmentOnly = Message(role: .assistant, content: "",
                                         imageFileNames: ["a.png"], imageFileSizes: [10])
            check("render: attachment-only assistant message IS an event with names",
                  (AppChatSocketServer.renderMessageEvent(attachmentOnly, queued: false)?["images"]
                    as? [String]) == ["a.png"])

            var userMessage = Message(role: .user, content: "hello",
                                      originChannel: ConversationManager.appChannelAddress)
            let userEvent = AppChatSocketServer.renderMessageEvent(userMessage, queued: true)
            check("render: typed user message includes origin and queued flag",
                  userEvent?["origin"] as? String == "app"
                  && userEvent?["queued"] as? Bool == true)

            userMessage.kind = .emailArrived
            check("render: ambient triggers (emailArrived) are not chat events",
                  AppChatSocketServer.renderMessageEvent(userMessage, queued: false) == nil)

            let activity = ConversationManager.TurnActivity(
                kind: .tools(["bash", "read_file"]), startedAt: Date())
            check("activity: tool names visible normally, generic under privacy",
                  AppChatSocketServer.activityDescription(activity, privacy: false) == "bash, read_file"
                  && AppChatSocketServer.activityDescription(activity, privacy: true) == "working…")
        }

        // ------------------------------------------------------------------
        // 2. Live server — seed a conversation, start, connect
        // ------------------------------------------------------------------
        let seededUser = Message(role: .user, content: "seeded question",
                                 originChannel: ConversationManager.appChannelAddress)
        let seededReply = Message(role: .assistant, content: "seeded answer")
        do {
            let data = try JSONEncoder().encode([seededUser, seededReply])
            // Roots are no longer created on resolution (diagnostics must not
            // materialize them) — a fixture that seeds state creates them.
            StoragePaths.ensureRoots()
            let conversationURL = StoragePaths.dataRoot.appendingPathComponent("conversation.json")
            try data.write(to: conversationURL)
        }

        let manager = await MainActor.run { ConversationManager() }
        let server = await MainActor.run { AppChatSocketServer() }
        await MainActor.run { server.start(manager: manager) }
        let socketPath = AppChatSocketServer.socketURL.path

        check("socket file exists after start",
              FileManager.default.fileExists(atPath: socketPath))
        var statInfo = stat()
        stat(socketPath, &statInfo)
        check("socket mode is 0600", statInfo.st_mode & 0o777 == 0o600,
              String(format: "%o", statInfo.st_mode & 0o777))

        guard var client = TestChatClient.connect(path: socketPath) else {
            check("client connects", false)
            print("RESULT: FAIL (cannot continue without a connection)")
            throw ExitCode(1)
        }
        defer { client.closeConnection() }

        // hello + snapshot
        if let hello = client.readEvent(ofType: "hello") {
            check("hello: protocol/version/media dirs present",
                  hello["protocol"] as? Int == AppChatSocketServer.protocolVersion
                  && (hello["version"] as? String)?.isEmpty == false
                  && (hello["images_dir"] as? String)?.isEmpty == false
                  && (hello["documents_dir"] as? String)?.isEmpty == false)
            let history = hello["history"] as? [[String: Any]] ?? []
            check("hello: history snapshot carries the seeded conversation in order",
                  history.count == 2
                  && history.first?["text"] as? String == "seeded question"
                  && history.last?["text"] as? String == "seeded answer")
            check("hello: privacy off, nothing withheld",
                  hello["privacy"] as? Bool == false && hello["history_withheld"] == nil)
        } else {
            check("hello received", false)
        }

        // ping / pong with ref correlation
        client.sendLine(["type": "ping", "ref": "p1"])
        let pong = client.readEvent(ofType: "pong")
        check("ping → pong with matching ref", pong?["ref"] as? String == "p1")

        // malformed line: error event, connection survives
        client.sendRaw("this is not json\n")
        let malformed = client.readEvent(ofType: "error")
        check("malformed line → error event",
              (malformed?["message"] as? String)?.contains("malformed") == true)
        client.sendLine(["type": "ping", "ref": "p2"])
        check("connection survives a malformed line",
              client.readEvent(ofType: "pong")?["ref"] as? String == "p2")

        // Browser settings is control traffic, never a model-visible command.
        let historyBeforeSettings = await MainActor.run { manager.messages.count }
        client.sendLine(["type": "browser_settings", "ref": "settings1"])
        let settingsAck = client.readEvent(ofType: "ack", timeoutSeconds: 20)
        if let link = settingsAck?["url"] as? String, let url = URL(string: link) {
            check("settings: socket returns a private loopback launch link", url.host == "127.0.0.1" && url.path == "/start")
            let config = URLSessionConfiguration.ephemeral
            let http = URLSession(configuration: config)
            let (html, response) = try await http.data(from: url)
            check("settings: running owner serves browser page", (response as? HTTPURLResponse)?.statusCode == 200 && String(data: html, encoding: .utf8)?.contains("Briglia settings") == true)
            let statusURL = URL(string: "/api/status", relativeTo: url)!
            let (statusData, _) = try await http.data(from: statusURL)
            let status = try JSONSerialization.jsonObject(with: statusData) as? [String: Any]
            check("settings: running owner mode reported", status?["running"] as? Bool == true)
            client.sendLine(["type": "browser_settings", "ref": "settings2"])
            let next = client.readEvent(ofType: "ack", timeoutSeconds: 20)
            check("settings: another launch replaces the URL", next?["url"] as? String != link)
            let (_, revoked) = try await http.data(from: statusURL)
            check("settings: old browser cookie revoked", (revoked as? HTTPURLResponse)?.statusCode == 404)
            http.invalidateAndCancel()
        } else { check("settings: socket launches browser settings", false) }
        // The actual command must delegate to the existing owner, rather
        // than opening a second standalone settings process.
        try KeychainHelper.save(key: SetupWizard.completeKey, value: "true")
        let ownerLease: InstanceLease
        switch InstanceLease.acquire(label: "settings owner fixture") {
        case .success(let lease): ownerLease = lease
        case .failure(let error): throw error
        }
        let launched = await Task.detached { () -> (Int32, String) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = ["quicksetup"]
            var environment = ProcessInfo.processInfo.environment
            environment["BRIGLIA_QUICKSETUP_NO_BROWSER"] = "1"
            environment["BRIGLIA_IGNORE_LEGACY_SETUP_FLAG"] = "1"
            process.environment = environment
            let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
            do { try process.run() } catch { return (-1, error.localizedDescription) }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        }.value
        ownerLease.release()
        check("settings: real CLI delegates to running owner", launched.0 == 0 && launched.1.contains("Settings are served by the running Briglia"))
        await BrowserSettingsHost.stopShared()
        check("settings: opening page does not modify conversation", await MainActor.run { manager.messages.count == historyBeforeSettings })

        // unknown type → nack
        client.sendLine(["type": "frobnicate", "ref": "u1"])
        check("unknown request type → nack",
              client.readEvent(ofType: "nack")?["ref"] as? String == "u1")

        // shared command set: real command handled, junk refused
        client.sendLine(["type": "command", "ref": "c1", "line": "/commands"])
        if let result = client.readEvent(ofType: "command_result", timeoutSeconds: 20) {
            check("command /commands handled with output lines",
                  result["ref"] as? String == "c1"
                  && result["handled"] as? Bool == true
                  && (result["lines"] as? [String])?.isEmpty == false)
        } else {
            check("command /commands answered", false)
        }
        client.sendLine(["type": "command", "ref": "c2", "line": "/definitelynotacommand"])
        check("unknown /command reports handled=false",
              client.readEvent(ofType: "command_result")?["handled"] as? Bool == false)
        client.sendLine(["type": "command", "ref": "c3", "line": "not-a-slash-line"])
        check("non-slash command line → nack",
              client.readEvent(ofType: "nack")?["ref"] as? String == "c3")

        // app commands must NOT redirect the ambient destination: before the
        // task-local capture, /status from the app pointed reminders and
        // alerts at the wireless .app channel until the next Telegram message
        // (Codex round 1, #2)
        let ambientKind = await MainActor.run { manager.ambientChannelKindForTesting }
        check("socket command leaves the ambient channel untouched",
              ambientKind != "app", ambientKind ?? "nil")

        // sends: empty and missing-attachment nacks
        client.sendLine(["type": "send", "ref": "s1", "text": "   "])
        check("empty send → nack",
              client.readEvent(ofType: "nack")?["ref"] as? String == "s1")
        client.sendLine(["type": "send", "ref": "s2", "text": "hi",
                         "attachments": [tempRoot.appendingPathComponent("nope.pdf").path]])
        check("missing attachment → nack",
              (client.readEvent(ofType: "nack")?["error"] as? String)?
                .contains("not found") == true)

        // non-regular files are refused before any read: a FIFO would hang a
        // naive open (no writer) and /dev/null reports size 0 — both must be
        // readable nacks, not hangs or exhaustion (Codex round 1, #3)
        let fifoPath = tempRoot.appendingPathComponent("chat-fifo").path
        mkfifo(fifoPath, 0o600)
        client.sendLine(["type": "send", "ref": "s2f", "text": "hi",
                         "attachments": [fifoPath]])
        check("FIFO attachment → refused as not a regular file",
              (client.readEvent(ofType: "nack")?["error"] as? String)?
                .contains("not a regular file") == true)
        client.sendLine(["type": "send", "ref": "s2d", "text": "hi",
                         "attachments": ["/dev/null"]])
        check("device attachment → refused as not a regular file",
              (client.readEvent(ofType: "nack")?["error"] as? String)?
                .contains("not a regular file") == true)
        client.sendLine(["type": "voice", "ref": "v2f", "path": fifoPath])
        check("FIFO voice path → refused as not a regular file",
              (client.readEvent(ofType: "nack")?["error"] as? String)?
                .contains("not a regular file") == true)

        // the streaming copier itself revalidates on the OPEN descriptor —
        // the security boundary behind the server's UX precheck
        do {
            let goodSource = tempRoot.appendingPathComponent("copy-src.bin")
            try Data(repeating: 0xAB, count: 300_000).write(to: goodSource)
            let goodDest = tempRoot.appendingPathComponent("copy-dst.bin")
            let copied = try await ConversationManager.copyRegularFile(
                from: goodSource, to: goodDest, maxBytes: 1_000_000)
            check("copyRegularFile: streams a regular file byte-exact",
                  copied == 300_000
                  && (try? Data(contentsOf: goodDest))?.count == 300_000)
            let overDest = tempRoot.appendingPathComponent("copy-over.bin")
            let overFailed: Bool
            do {
                _ = try await ConversationManager.copyRegularFile(
                    from: goodSource, to: overDest, maxBytes: 100_000)
                overFailed = false
            } catch { overFailed = true }
            check("copyRegularFile: cap enforced on actual bytes read + partial removed",
                  overFailed && !FileManager.default.fileExists(atPath: overDest.path))
            let fifoFailed: Bool
            do {
                _ = try await ConversationManager.copyRegularFile(
                    from: URL(fileURLWithPath: fifoPath),
                    to: tempRoot.appendingPathComponent("copy-fifo.bin"),
                    maxBytes: 1_000_000)
                fifoFailed = false
            } catch { fifoFailed = true }
            check("copyRegularFile: open-descriptor revalidation rejects a FIFO without hanging",
                  fifoFailed)

            // exclusive name reservation: a destination that appears between
            // the name pick and the create must throw the retryable
            // CopyDestinationExists WITHOUT touching the existing bytes —
            // the old create-then-open path silently truncated it
            let occupied = tempRoot.appendingPathComponent("copy-occupied.bin")
            try Data("precious".utf8).write(to: occupied)
            var sawExists = false
            do {
                _ = try await ConversationManager.copyRegularFile(
                    from: goodSource, to: occupied, maxBytes: 1_000_000)
            } catch is ConversationManager.CopyDestinationExists {
                sawExists = true
            } catch {}
            check("copyRegularFile: O_EXCL create — existing destination survives untouched",
                  sawExists
                  && (try? Data(contentsOf: occupied)) == Data("precious".utf8))

            // per-front-end limits (Codex regression audit 2026-08-29): the
            // remote app socket keeps 100 MB + non-empty; the LOCAL terminal
            // /attach restores its pre-socket semantics — no cap, empty ok
            check("attachment policy: terminal uncapped + allows empty, app socket unchanged",
                  ConversationManager.AttachmentPolicy.terminal.maxBytes == Int.max
                  && ConversationManager.AttachmentPolicy.terminal.allowEmpty
                  && ConversationManager.AttachmentPolicy.appSocket.maxBytes
                      == AppChatSocketServer.maxAttachmentBytes
                  && !ConversationManager.AttachmentPolicy.appSocket.allowEmpty)
            let emptySource = tempRoot.appendingPathComponent("copy-empty.bin")
            try Data().write(to: emptySource)
            var emptyRejectedForApp = false
            do {
                _ = try await ConversationManager.copyRegularFile(
                    from: emptySource,
                    to: tempRoot.appendingPathComponent("copy-empty-app.bin"),
                    maxBytes: 1_000_000)
            } catch { emptyRejectedForApp = true }
            let emptyTermDest = tempRoot.appendingPathComponent("copy-empty-term.bin")
            let emptyCopied = try await ConversationManager.copyRegularFile(
                from: emptySource, to: emptyTermDest,
                maxBytes: Int.max, allowEmpty: true)
            check("copyRegularFile: empty file refused for the app, accepted for the terminal",
                  emptyRejectedForApp && emptyCopied == 0
                  && FileManager.default.fileExists(atPath: emptyTermDest.path))
        }

        // durable acceptance: no provider is configured in this sandbox, so
        // the manager cannot accept the message — the app must get an honest
        // NACK (composer restored) instead of the old blind ack + error event,
        // and nothing may be half-appended to history (Codex round 1, #4)
        let historyCountBefore = await MainActor.run { manager.messages.count }
        client.sendLine(["type": "send", "ref": "s3", "text": "hello ada"])
        let s3nack = client.readEvent(ofType: "nack", timeoutSeconds: 20)
        check("unaccepted send → honest nack with the startup failure",
              s3nack?["ref"] as? String == "s3"
              && (s3nack?["error"] as? String)?.isEmpty == false)
        let historyCountAfter = await MainActor.run { manager.messages.count }
        check("refused send leaves history untouched (no half-append)",
              historyCountBefore == historyCountAfter)

        // voice: no transcription key configured → nack explains
        let voiceFile = tempRoot.appendingPathComponent("note.ogg")
        try Data([0x4F, 0x67, 0x67, 0x53]).write(to: voiceFile)
        client.sendLine(["type": "voice", "ref": "v1", "path": voiceFile.path])
        check("voice without a transcription key → explanatory nack",
              (client.readEvent(ofType: "nack", timeoutSeconds: 20)?["error"] as? String)?
                .contains("transcription") == true)
        client.sendLine(["type": "voice", "ref": "v2",
                         "path": tempRoot.appendingPathComponent("ghost.ogg").path])
        check("voice with missing file → nack",
              client.readEvent(ofType: "nack")?["ref"] as? String == "v2")

        // stop is always safe
        client.sendLine(["type": "stop", "ref": "st1"])
        check("stop → ack", client.readEvent(ofType: "ack")?["ref"] as? String == "st1")

        // ------------------------------------------------------------------
        // 3. Broadcasts, second client, privacy withhold/replay
        // ------------------------------------------------------------------
        guard var client2 = TestChatClient.connect(path: socketPath) else {
            check("second client connects", false)
            print("RESULT: FAIL")
            throw ExitCode(1)
        }
        defer { client2.closeConnection() }
        check("second client gets its own hello",
              client2.readEvent(ofType: "hello") != nil)

        // concurrent commands from two clients: each capture is task-local,
        // so both must receive their own complete response — the old single
        // global capture could hand one client the other's lines (or an
        // empty result)
        client.sendLine(["type": "command", "ref": "cc1", "line": "/commands"])
        client2.sendLine(["type": "command", "ref": "cc2", "line": "/commands"])
        let cc1 = client.readEvent(ofType: "command_result", timeoutSeconds: 20)
        let cc2 = client2.readEvent(ofType: "command_result", timeoutSeconds: 20)
        let cc1Text = (cc1?["lines"] as? [String])?.joined(separator: "\n") ?? ""
        let cc2Text = (cc2?["lines"] as? [String])?.joined(separator: "\n") ?? ""
        check("concurrent commands: both clients get their own complete response",
              cc1?["ref"] as? String == "cc1" && cc2?["ref"] as? String == "cc2"
              && cc1Text.contains("/status") && cc2Text.contains("/status"))

        await MainActor.run { manager.error = "test-broadcast-error" }
        let e1 = client.readEvent(ofType: "error") { ($0["message"] as? String) == "test-broadcast-error" }
        let e2 = client2.readEvent(ofType: "error") { ($0["message"] as? String) == "test-broadcast-error" }
        check("published error broadcasts to every client", e1 != nil && e2 != nil)

        // live history append → message event
        let liveReply = Message(role: .assistant, content: "live broadcast test")
        await MainActor.run { manager.messages.append(liveReply) }
        check("appended history message broadcasts to clients",
              client.readEvent(ofType: "message") { ($0["text"] as? String) == "live broadcast test" } != nil
              && client2.readEvent(ofType: "message") { ($0["text"] as? String) == "live broadcast test" } != nil)

        // privacy: withhold now, replay on /show
        await MainActor.run { manager.isPrivacyModeEnabled = true }
        _ = client.readEvent(ofType: "status") { ($0["privacy"] as? Bool) == true }
        let hiddenReply = Message(role: .assistant, content: "secret while hidden")
        await MainActor.run { manager.messages.append(hiddenReply) }
        let leaked = client.readEvent(ofType: "message", timeoutSeconds: 2) {
            ($0["text"] as? String) == "secret while hidden"
        }
        check("privacy mode withholds message events", leaked == nil)

        // a client connecting during privacy gets no history
        if var client3 = TestChatClient.connect(path: socketPath) {
            let hello3 = client3.readEvent(ofType: "hello")
            check("hello during privacy: history withheld",
                  hello3?["history_withheld"] as? Bool == true
                  && (hello3?["history"] as? [[String: Any]])?.isEmpty == true)
            client3.closeConnection()
        } else {
            check("third client connects during privacy", false)
        }

        await MainActor.run { manager.isPrivacyModeEnabled = false }
        check("/show replays the withheld message",
              client.readEvent(ofType: "message", timeoutSeconds: 10) {
                  ($0["text"] as? String) == "secret while hidden"
              } != nil)

        // ------------------------------------------------------------------
        // 4. Restart over a stale socket file
        // ------------------------------------------------------------------
        await MainActor.run { server.stop() }
        check("stop removes the socket file",
              !FileManager.default.fileExists(atPath: socketPath))
        // a crashed process leaves a stale file behind — start must rebind
        FileManager.default.createFile(atPath: socketPath, contents: Data("stale".utf8))
        let server2 = await MainActor.run { AppChatSocketServer() }
        await MainActor.run { server2.start(manager: manager) }
        if var client4 = TestChatClient.connect(path: socketPath) {
            check("restart rebinds over a stale socket file",
                  client4.readEvent(ofType: "hello") != nil)
            client4.closeConnection()
        } else {
            check("restart rebinds over a stale socket file", false)
        }
        await MainActor.run { server2.stop() }

        print(failures == 0 ? "RESULT: PASS" : "RESULT: FAIL (\(failures) failure(s))")
        if failures > 0 { throw ExitCode(1) }
    }
}

// MARK: - Blocking test client

/// Minimal JSON-lines client used only by the selftest: blocking POSIX I/O
/// with poll()-based deadlines, deliberately independent of the server's own
/// I/O code so a shared bug can't hide itself.
struct TestChatClient {
    let fd: Int32
    var buffer = Data()

    static func connect(path: String) -> TestChatClient? {
        #if canImport(Glibc)
        let streamType = Int32(SOCK_STREAM.rawValue)
        #else
        let streamType = SOCK_STREAM
        #endif
        let fd = socket(AF_UNIX, streamType, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= capacity else { close(fd); return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            pathBytes.withUnsafeBytes { src in dst.copyBytes(from: src.prefix(capacity)) }
        }
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr -> Int32 in
                #if canImport(Glibc)
                return Glibc.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                #else
                return Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                #endif
            }
        }
        guard result == 0 else { close(fd); return nil }
        return TestChatClient(fd: fd)
    }

    func sendLine(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        _ = data.withUnsafeBytes { raw in
            write(fd, raw.baseAddress, raw.count)
        }
    }

    func sendRaw(_ text: String) {
        let data = Data(text.utf8)
        _ = data.withUnsafeBytes { raw in
            write(fd, raw.baseAddress, raw.count)
        }
    }

    /// Next event of the given type (others are skipped), or nil on timeout.
    /// `matching` further filters events of that type.
    mutating func readEvent(
        ofType type: String,
        timeoutSeconds: Double = 10,
        matching: ([String: Any]) -> Bool = { _ in true }
    ) -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while true {
            if let event = nextBufferedEvent() {
                if event["type"] as? String == type, matching(event) { return event }
                continue
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let rc = poll(&pfd, 1, Int32(min(remaining, 0.25) * 1000) + 1)
            if rc < 0 && errno != EINTR { return nil }
            if rc > 0 {
                var chunk = [UInt8](repeating: 0, count: 65536)
                let n = read(fd, &chunk, 65536)
                if n <= 0 { return nil }
                buffer.append(contentsOf: chunk[0..<n])
            }
        }
    }

    private mutating func nextBufferedEvent() -> [String: Any]? {
        guard let nl = buffer.firstIndex(of: 0x0A) else { return nil }
        let lineData = buffer.subdata(in: buffer.startIndex..<nl)
        buffer.removeSubrange(buffer.startIndex...nl)
        return (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any]
    }

    func closeConnection() {
        close(fd)
    }
}
