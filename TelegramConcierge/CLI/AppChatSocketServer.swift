import Foundation
#if canImport(Combine)
import Combine
#else
import OpenCombine
import OpenCombineDispatch
#endif
#if canImport(Glibc)
import Glibc
#endif

/// JSON-lines chat server on a Unix domain socket — the wire behind the
/// Ubuntu Touch companion app's chat window.
///
/// Like TerminalSession, this is a FRONT-END over ConversationManager, not a
/// transport: input enters via `sendFromApp` (origin channel `.app`), and
/// output is the observed published conversation history — so nothing here
/// touches channel routing, tool schemas, or any model-visible surface.
/// Several clients may connect at once (each gets a history snapshot plus
/// live events), and the terminal REPL can be open at the same time.
///
/// Security: the socket is chmod 0600 inside the user's data root, and every
/// accepted connection must present our own UID (SO_PEERCRED on Linux,
/// getpeereid on macOS) before a single byte is parsed. A process that
/// passes that check already holds every privilege `briglia` itself has — the
/// socket grants nothing new.
///
/// Privacy mode (`/hide`) applies to this window exactly like the terminal:
/// message events are withheld while enabled and replayed in order on
/// `/show`; tool names in activity updates degrade to a generic "working…".
@MainActor
final class AppChatSocketServer {
    static let shared = AppChatSocketServer()

    nonisolated static let protocolVersion = 1
    /// History snapshot size on connect — fills any phone screen many times
    /// over without shipping a whole long-lived conversation.
    nonisolated static let historySnapshotLimit = 200
    /// Inbound line cap. Requests carry text and file PATHS, never bytes, so
    /// a line beyond this is a broken or hostile client.
    nonisolated static let maxInboundLineBytes = 1_048_576
    /// Per-file cap for `send` attachments — copies are streamed, but the
    /// media folder lives on a phone's disk; refuse anything that would hurt.
    nonisolated static let maxAttachmentBytes = 100 * 1024 * 1024
    /// Voice notes are minutes of Opus/WAV, not gigabytes.
    nonisolated static let maxVoiceBytes = 50 * 1024 * 1024

    nonisolated static var socketURL: URL {
        StoragePaths.dataRoot.appendingPathComponent("app-chat.sock")
    }

    private weak var manager: ConversationManager?
    private var cancellables = Set<AnyCancellable>()
    private var listenerFD: Int32 = -1
    private var clients: [ClientHandle] = []
    private var nextClientId = 0

    /// Message ids already broadcast as final history entries.
    private var broadcastFinalIds = Set<UUID>()
    /// Message ids broadcast in their queued (mid-turn pending) form.
    private var broadcastQueuedIds = Set<UUID>()
    /// Message events withheld while privacy mode is active, replayed in
    /// order on /show — TerminalSession's hiddenWhilePrivate contract.
    private var heldWhilePrivate: [[String: Any]] = []

    #if canImport(Combine)
    private var mainScheduler: DispatchQueue { DispatchQueue.main }
    #else
    private var mainScheduler: DispatchQueue.OCombine { DispatchQueue.main.ocombine }
    #endif

    // MARK: - Lifecycle

    /// Bind, subscribe, and start accepting. Failure to bind is loud but
    /// non-fatal: the agent keeps running on its other channels.
    func start(manager: ConversationManager) {
        guard listenerFD < 0 else { return }
        self.manager = manager
        // Seed dedup with existing history so startup doesn't re-broadcast
        // the whole conversation (clients receive it via their snapshot).
        broadcastFinalIds = Set(manager.messages.map(\.id))
        broadcastQueuedIds = Set(manager.pendingMidTurnMessages.map(\.id))

        let path = Self.socketURL.path
        guard let fd = Self.makeListener(path: path) else { return }
        listenerFD = fd
        subscribe(to: manager)
        startAcceptLoop(listenerFD: fd)
    }

    /// Close the listener and every client. Used by shutdown and tests; a
    /// crashed process instead relies on the next start()'s stale unlink.
    func stop() {
        if listenerFD >= 0 {
            shutdown(listenerFD, Int32(SHUT_RDWR))
            close(listenerFD)
            listenerFD = -1
        }
        unlink(Self.socketURL.path)
        for client in clients { client.shutdownConnection() }
        clients.removeAll()
        cancellables.removeAll()
        broadcastFinalIds.removeAll()
        broadcastQueuedIds.removeAll()
        heldWhilePrivate.removeAll()
    }

    private nonisolated static func makeListener(path: String) -> Int32? {
        // sockaddr_un caps the path (104/108 bytes). The production path
        // (~/.local/share/briglia/app-chat.sock) is far below it; exotic
        // $XDG_DATA_HOME overrides get a readable refusal, not a crash.
        var addr = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= capacity else {
            print("[AppChatSocket] ✖ socket path too long for sockaddr_un (\(path)) — app chat disabled")
            return nil
        }
        unlink(path)  // stale socket from a crashed predecessor

        #if canImport(Glibc)
        let streamType = Int32(SOCK_STREAM.rawValue)
        #else
        let streamType = SOCK_STREAM
        #endif
        let fd = socket(AF_UNIX, streamType, 0)
        guard fd >= 0 else {
            print("[AppChatSocket] ✖ socket() failed (errno \(errno)) — app chat disabled")
            return nil
        }
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            pathBytes.withUnsafeBytes { src in
                dst.copyBytes(from: src.prefix(capacity))
            }
        }
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            print("[AppChatSocket] ✖ bind(\(path)) failed (errno \(errno)) — app chat disabled")
            close(fd)
            return nil
        }
        // 0600 immediately after bind. Defense in depth only — the peer-UID
        // check on every accept is the real gate.
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else {
            print("[AppChatSocket] ✖ listen() failed (errno \(errno)) — app chat disabled")
            close(fd)
            unlink(path)
            return nil
        }
        return fd
    }

    private nonisolated func startAcceptLoop(listenerFD: Int32) {
        Thread.detachNewThread { [weak self] in
            while true {
                let fd = accept(listenerFD, nil, nil)
                if fd < 0 {
                    if errno == EINTR { continue }
                    break  // listener closed (stop()) or fatal
                }
                guard let peer = Self.peerUID(of: fd), peer == getuid() else {
                    print("[AppChatSocket] refused connection: peer UID mismatch")
                    close(fd)
                    continue
                }
                // A client that stops reading must not pin a write thread or
                // grow its event queue forever: a stalled send times out,
                // marks the client failed, and cleanup closes it.
                var sendTimeout = timeval(tv_sec: 10, tv_usec: 0)
                _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO,
                               &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
                #if !canImport(Glibc)
                // Belt and braces on Darwin: suppress SIGPIPE at the socket
                // level too, so a write racing a client hangup is a plain
                // EPIPE even in entry points that skipped prepareIO()'s
                // process-wide ignore. (Linux has no SO_NOSIGPIPE; the
                // daemon's SIG_IGN covers it there.)
                var noSigpipe: Int32 = 1
                _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE,
                               &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
                #endif
                Task { @MainActor [weak self] in
                    self?.addClient(fd: fd)
                }
            }
        }
    }

    #if canImport(Glibc)
    /// Swift's Glibc module does not export `struct ucred` (its _GNU_SOURCE
    /// gating defeats the importer), so mirror its fixed kernel layout —
    /// pid/uid/gid, three 32-bit fields on every Linux ABI — and read
    /// SO_PEERCRED into it manually. SO_PEERCRED itself is also unexported;
    /// it is 17 in asm-generic (x86-64, arm64, riscv — every target Briglia
    /// ships for; only historic sparc/parisc differ).
    private struct LinuxPeerCred {
        var pid: Int32 = 0
        var uid: UInt32 = 0
        var gid: UInt32 = 0
    }
    nonisolated private static let soPeerCred: Int32 = 17
    #endif

    /// UID of the process on the other end of a connected Unix socket.
    nonisolated static func peerUID(of fd: Int32) -> uid_t? {
        #if canImport(Glibc)
        var cred = LinuxPeerCred()
        var len = socklen_t(MemoryLayout<LinuxPeerCred>.size)
        guard getsockopt(fd, SOL_SOCKET, soPeerCred, &cred, &len) == 0,
              len == socklen_t(MemoryLayout<LinuxPeerCred>.size) else { return nil }
        return uid_t(cred.uid)
        #else
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return nil }
        return uid
        #endif
    }

    // MARK: - Client management

    private func addClient(fd: Int32) {
        let handle = ClientHandle(id: nextClientId, fd: fd)
        nextClientId += 1
        clients.append(handle)
        sendHello(to: handle)

        // Reader thread yields whole lines into an ordered stream; a single
        // MainActor task consumes them so requests are handled in arrival
        // order (independent Tasks per line would not guarantee that).
        let (stream, continuation) = AsyncStream<String>.makeStream()
        let maxBytes = Self.maxInboundLineBytes
        Thread.detachNewThread {
            var buffer = Data()
            var overflowed = false
            reading: while true {
                var chunk = [UInt8](repeating: 0, count: 65536)
                let n = read(fd, &chunk, 65536)
                if n == 0 { break }
                if n < 0 {
                    if errno == EINTR { continue }
                    break
                }
                buffer.append(contentsOf: chunk[0..<n])
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                    buffer.removeSubrange(buffer.startIndex...nl)
                    if let line = String(data: lineData, encoding: .utf8),
                       !line.trimmingCharacters(in: .whitespaces).isEmpty {
                        continuation.yield(line)
                    }
                }
                if buffer.count > maxBytes {
                    overflowed = true
                    break reading
                }
            }
            if overflowed {
                handle.send(["type": "error",
                             "message": "request line exceeds \(maxBytes) bytes — closing connection"])
            }
            continuation.finish()
        }
        Task { @MainActor [weak self] in
            for await line in stream {
                await self?.handle(line: line, from: handle)
            }
            self?.removeClient(handle)
        }
    }

    private func removeClient(_ handle: ClientHandle) {
        clients.removeAll { $0 === handle }
        handle.closeConnection()
    }

    private func broadcast(_ event: [String: Any]) {
        for client in clients { client.send(event) }
    }

    // MARK: - Outbound events

    private func subscribe(to manager: ConversationManager) {
        manager.$messages
            .receive(on: mainScheduler)
            .sink { [weak self] messages in self?.broadcastNewMessages(messages) }
            .store(in: &cancellables)

        manager.$pendingMidTurnMessages
            .receive(on: mainScheduler)
            .sink { [weak self] pending in self?.broadcastQueuedMessages(pending) }
            .store(in: &cancellables)

        manager.$isTurnActive
            .removeDuplicates()
            .receive(on: mainScheduler)
            .sink { [weak self] _ in self?.broadcastStatus() }
            .store(in: &cancellables)

        manager.$turnActivity
            .receive(on: mainScheduler)
            .sink { [weak self] _ in self?.broadcastStatus() }
            .store(in: &cancellables)

        manager.$statusMessage
            .removeDuplicates()
            .receive(on: mainScheduler)
            .sink { [weak self] _ in self?.broadcastStatus() }
            .store(in: &cancellables)

        manager.$isPrivacyModeEnabled
            .removeDuplicates()
            .receive(on: mainScheduler)
            .sink { [weak self] enabled in self?.privacyModeChanged(enabled) }
            .store(in: &cancellables)

        manager.$error
            .compactMap { $0 }
            .removeDuplicates()
            .receive(on: mainScheduler)
            .sink { [weak self] message in
                self?.broadcast(["type": "error", "message": message])
            }
            .store(in: &cancellables)

        manager.$maintenanceNotice
            .compactMap { $0 }
            .removeDuplicates()
            .receive(on: mainScheduler)
            .sink { [weak self] message in
                self?.broadcast(["type": "notice", "message": message])
            }
            .store(in: &cancellables)
    }

    private func broadcastNewMessages(_ messages: [Message]) {
        for message in messages where !broadcastFinalIds.contains(message.id) {
            broadcastFinalIds.insert(message.id)
            guard let event = Self.renderMessageEvent(message, queued: false) else { continue }
            deliverMessageEvent(event)
        }
    }

    private func broadcastQueuedMessages(_ pending: [Message]) {
        for message in pending
        where !broadcastQueuedIds.contains(message.id) && !broadcastFinalIds.contains(message.id) {
            broadcastQueuedIds.insert(message.id)
            guard let event = Self.renderMessageEvent(message, queued: true) else { continue }
            deliverMessageEvent(event)
        }
    }

    private func deliverMessageEvent(_ event: [String: Any]) {
        if manager?.isPrivacyModeEnabled == true {
            heldWhilePrivate.append(event)
        } else {
            broadcast(event)
        }
    }

    private func privacyModeChanged(_ enabled: Bool) {
        if !enabled, !heldWhilePrivate.isEmpty {
            for event in heldWhilePrivate { broadcast(event) }
            heldWhilePrivate.removeAll()
        }
        broadcastStatus()
    }

    private func broadcastStatus() {
        broadcast(currentStatusEvent())
    }

    private func currentStatusEvent() -> [String: Any] {
        var event: [String: Any] = ["type": "status"]
        guard let manager else { return event }
        event["turn_active"] = manager.isTurnActive
        event["privacy"] = manager.isPrivacyModeEnabled
        event["status"] = manager.statusMessage
        if let activity = manager.turnActivity {
            event["activity"] = Self.activityDescription(
                activity, privacy: manager.isPrivacyModeEnabled)
        }
        return event
    }

    /// Fast, readable refusal for an attachment path before it is handed to
    /// the manager: must exist, be a REGULAR file (stat follows symlinks, so
    /// a link to a real file passes; FIFOs, devices and sockets are refused —
    /// /dev/zero reports size 0 and would otherwise pass a size gate straight
    /// into an unbounded read), and fit the size cap. This is UX, not the
    /// security boundary: the manager's copyRegularFile revalidates on the
    /// open descriptor and enforces the cap on actual bytes read.
    nonisolated static func attachmentPrecheckProblem(
        path: String,
        maxBytes: Int = AppChatSocketServer.maxAttachmentBytes,
        label: String = "attachment"
    ) -> String? {
        var info = stat()
        guard stat(path, &info) == 0 else {
            return "\(label) not found: \(path)"
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            return "\(label) is not a regular file (directory, device, or pipe): \(path)"
        }
        guard info.st_size <= off_t(maxBytes) else {
            return "\(label) too large (>\(maxBytes / 1_048_576) MB): \(path)"
        }
        return nil
    }

    /// Mirror of TerminalSession.renderActivity — tool names can leak what
    /// the conversation is about, so privacy mode degrades them.
    nonisolated static func activityDescription(
        _ activity: ConversationManager.TurnActivity, privacy: Bool
    ) -> String {
        switch activity.kind {
        case .thinking:
            return "thinking…"
        case .tools(let names):
            return privacy ? "working…" : names.joined(separator: ", ")
        }
    }

    /// Render one history message as a wire event, or nil when it isn't part
    /// of the visible conversation (synthetic triggers, empty tool-run
    /// shells). Pure — pinned by the selftest. Events are upserts by id: a
    /// queued mid-turn message is re-sent with queued=false once it enters
    /// history proper.
    nonisolated static func renderMessageEvent(_ message: Message, queued: Bool) -> [String: Any]? {
        switch message.role {
        case .assistant:
            let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasAttachments = !(message.imageFileNames.isEmpty
                && message.documentFileNames.isEmpty
                && message.generatedFilePaths.isEmpty)
            guard !text.isEmpty || hasAttachments else { return nil }
        case .user:
            // Ambient triggers (email arrivals, reminder fires, background
            // completions) are agent input, not the user speaking.
            guard message.kind == .userText else { return nil }
        }
        var event: [String: Any] = [
            "type": "message",
            "id": message.id.uuidString,
            "role": message.role.rawValue,
            "text": message.content,
            "ts": message.timestamp.timeIntervalSince1970,
            "queued": queued,
        ]
        if !message.imageFileNames.isEmpty { event["images"] = message.imageFileNames }
        if !message.documentFileNames.isEmpty { event["documents"] = message.documentFileNames }
        if !message.generatedFilePaths.isEmpty { event["generated"] = message.generatedFilePaths }
        if let origin = message.originChannel { event["origin"] = origin.kind.rawValue }
        return event
    }

    private func sendHello(to client: ClientHandle) {
        guard let manager else {
            client.send(["type": "error", "message": "agent not ready"])
            return
        }
        let media = manager.mediaDirectoryPaths
        let privacy = manager.isPrivacyModeEnabled
        var history: [[String: Any]] = []
        if !privacy {
            history = Array(
                manager.messages
                    .compactMap { Self.renderMessageEvent($0, queued: false) }
                    .suffix(Self.historySnapshotLimit))
            history += manager.pendingMidTurnMessages
                .compactMap { Self.renderMessageEvent($0, queued: true) }
        }
        var hello: [String: Any] = [
            "type": "hello",
            "protocol": Self.protocolVersion,
            "version": adaCLIVersion,
            "images_dir": media.images,
            "documents_dir": media.documents,
            "privacy": privacy,
            "turn_active": manager.isTurnActive,
            "status": manager.statusMessage,
            "history": history,
        ]
        if privacy { hello["history_withheld"] = true }
        client.send(hello)
    }

    // MARK: - Inbound requests

    private func handle(line: String, from client: ClientHandle) async {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String else {
            client.send(["type": "error",
                         "message": "malformed request line (expected a JSON object with a \"type\")"])
            return
        }
        let ref = object["ref"] as? String

        func ack(_ extra: [String: Any] = [:]) {
            var event: [String: Any] = ["type": "ack"]
            if let ref { event["ref"] = ref }
            for (key, value) in extra { event[key] = value }
            client.send(event)
        }
        func nack(_ message: String) {
            var event: [String: Any] = ["type": "nack", "error": message]
            if let ref { event["ref"] = ref }
            client.send(event)
        }

        guard let manager else {
            nack("agent not ready")
            return
        }

        switch type {
        case "browser_settings":
            do {
                let url = try await BrowserSettingsHost.open(manager: manager)
                ack(["url": url])
            } catch { nack("Could not open browser settings: \(error.localizedDescription)") }

        case "ping":
            var event: [String: Any] = ["type": "pong"]
            if let ref { event["ref"] = ref }
            client.send(event)

        case "send":
            let text = (object["text"] as? String) ?? ""
            let rawPaths = (object["attachments"] as? [String]) ?? []
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty || !rawPaths.isEmpty else {
                nack("empty message")
                return
            }
            var urls: [URL] = []
            for raw in rawPaths {
                let path = (raw as NSString).expandingTildeInPath
                if let problem = Self.attachmentPrecheckProblem(path: path) {
                    nack(problem)
                    return
                }
                urls.append(URL(fileURLWithPath: path))
            }
            // Awaited in the request loop (not fire-and-forget) so the ack is
            // sent only AFTER the manager durably accepted the message —
            // history saved or mid-turn queue mirrored to disk. The app keeps
            // its composer text until this ack, so a crash, restore gate, or
            // refusal can no longer lose the message silently. sendFromApp
            // starts the turn without awaiting it, so the loop stays
            // responsive for stop/ping mid-turn; the attachment copy streams
            // off the main actor and is bounded by the size cap.
            switch await manager.sendFromApp(text: text, attachments: urls) {
            case .accepted:
                ack()
            case .refused(let reason):
                nack(reason)
            }

        case "voice":
            guard let rawPath = object["path"] as? String, !rawPath.isEmpty else {
                nack("missing voice file path")
                return
            }
            let path = (rawPath as NSString).expandingTildeInPath
            if let problem = Self.attachmentPrecheckProblem(
                path: path, maxBytes: Self.maxVoiceBytes, label: "voice file") {
                nack(problem)
                return
            }
            // Transcription can take seconds — never block the request loop.
            // The app owns the file and deletes it after ack/nack. The ack is
            // sent only after the transcribed text was durably ACCEPTED by
            // the manager — a transcription that then fails to enqueue is an
            // honest nack, so the app keeps the recording visible as failed
            // instead of silently losing the note.
            Task { @MainActor in
                let result = await manager.transcribeAppVoice(
                    audioURL: URL(fileURLWithPath: path))
                switch result {
                case .success(let transcription):
                    switch await manager.sendFromApp(text: transcription, attachments: []) {
                    case .accepted:
                        ack(["transcription": transcription])
                    case .refused(let reason):
                        nack(reason)
                    }
                case .failure(let error):
                    nack(error.userMessage)
                }
            }

        case "stop":
            await manager.stopFromApp()
            ack()

        case "command":
            guard let commandLine = (object["line"] as? String)?
                    .trimmingCharacters(in: .whitespaces),
                  commandLine.hasPrefix("/") else {
                nack("command must start with /")
                return
            }
            // Same shared command set the terminal and Telegram use. Runs
            // detached: some commands (e.g. /prune) take a while.
            Task { @MainActor in
                let responses = await manager.handleTerminalCommand(commandLine)
                var event: [String: Any] = [
                    "type": "command_result",
                    "handled": responses != nil,
                    "lines": responses ?? [],
                ]
                if let ref { event["ref"] = ref }
                client.send(event)
            }

        default:
            nack("unknown request type \"\(type)\"")
        }
    }
}

// MARK: - Client handle

/// One connected client. Writes are serialized on a private queue so events
/// from any thread interleave whole-line; the writer never closes the fd —
/// on failure it shuts the socket down, the reader thread notices EOF, and
/// the MainActor cleanup path performs the single close.
final class ClientHandle: @unchecked Sendable {
    let id: Int
    let fd: Int32
    private let writeQueue: DispatchQueue
    private var writeFailed = false
    private var closed = false

    init(id: Int, fd: Int32) {
        self.id = id
        self.fd = fd
        self.writeQueue = DispatchQueue(label: "com.permaevidence.briglia.app-chat.write.\(id)")
    }

    func send(_ event: [String: Any]) {
        writeQueue.async { [self] in
            guard !writeFailed, !closed else { return }
            guard JSONSerialization.isValidJSONObject(event),
                  var data = try? JSONSerialization.data(withJSONObject: event) else {
                print("[AppChatSocket] dropped unencodable event")
                return
            }
            data.append(0x0A)
            let ok = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
                var offset = 0
                while offset < raw.count {
                    let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if n < 0 {
                        if errno == EINTR { continue }
                        return false  // EPIPE etc. (SIGPIPE is ignored process-wide)
                    }
                    if n == 0 { return false }
                    offset += n
                }
                return true
            }
            if !ok {
                writeFailed = true
                shutdown(fd, Int32(SHUT_RDWR))  // wake the reader → cleanup
            }
        }
    }

    /// Half-close from the server side (stop()): wakes the reader thread,
    /// whose stream finish triggers the owning task's removeClient.
    func shutdownConnection() {
        writeQueue.async { [self] in
            guard !closed else { return }
            shutdown(fd, Int32(SHUT_RDWR))
        }
    }

    /// The single close, called exactly once from removeClient after the
    /// reader finished. Runs on the write queue so any queued events flush
    /// (or fail) before the fd number can be reused.
    func closeConnection() {
        writeQueue.async { [self] in
            guard !closed else { return }
            closed = true
            close(fd)
        }
    }
}
