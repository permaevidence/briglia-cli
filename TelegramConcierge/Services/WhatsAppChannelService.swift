import Foundation
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif

/// Inbound WhatsApp message, normalized by the Node bridge.
struct WhatsAppInboundMessage: Decodable {
    struct Quoted: Decodable {
        let text: String
        let fromMe: Bool
    }
    struct Media: Decodable {
        let kind: String        // image | video | document | voice | audio (a non-PTT audio file: a file, never transcribed)
        let path: String        // absolute path in the bridge's media spool
        let filename: String
        let mimeType: String?
        let sizeBytes: Int?
    }

    let from: String            // JID to reply to
    let timestamp: Int?
    let text: String?
    let caption: String?
    let quoted: Quoted?
    let media: Media?
    let mediaError: String?
}

/// Connection lifecycle, surfaced in Settings and used to gate sends.
enum WhatsAppConnectionState: Equatable {
    case disabled
    case installing
    case starting
    case waitingForQR
    case connected(me: String?)
    case disconnected(detail: String)
    case loggedOut
    case failed(String)

    var description: String {
        switch self {
        case .disabled: return "Disabled"
        case .installing: return "Installing bridge dependencies…"
        case .starting: return "Starting…"
        case .waitingForQR: return "Scan the QR code with WhatsApp"
        case .connected(let me): return "Connected\(me.map { " (\($0.split(separator: ":").first.map(String.init) ?? $0))" } ?? "")"
        case .disconnected(let detail): return "Disconnected: \(detail)"
        case .loggedOut: return "Logged out — re-pair to continue"
        case .failed(let msg): return "Error: \(msg)"
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// Supervises the Baileys Node sidecar and exposes WhatsApp as a ChatChannel.
///
/// The bridge process speaks JSON-lines over stdio (see Resources/WhatsAppBridge/index.js).
/// Inbound messages are buffered here and drained by ConversationManager's poll
/// loop, mirroring how Telegram updates flow — so both transports share the
/// same single-turn-at-a-time discipline.
@MainActor
final class WhatsAppChannelService: ObservableObject {
    static let shared = WhatsAppChannelService()

    @Published private(set) var state: WhatsAppConnectionState = .disabled
    /// Raw QR payload from Baileys while pairing — rendered by the settings UI.
    @Published private(set) var qrString: String?

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutBuffer = Data()
    private var inboundQueue: [WhatsAppInboundMessage] = []
    private var pendingAcks: [String: CheckedContinuation<Void, Error>] = [:]
    private var nextCommandId = 0
    private var restartAttempts = 0
    private var intentionallyStopped = true
    private var lastStderrTail = ""

    static let enabledDefaultsKey = "whatsapp_enabled"

    enum WhatsAppError: LocalizedError {
        case notConnected
        case bridgeMissing(String)
        case sendFailed(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .notConnected: return "WhatsApp is not connected"
            case .bridgeMissing(let detail): return "WhatsApp bridge unavailable: \(detail)"
            case .sendFailed(let detail): return "WhatsApp send failed: \(detail)"
            case .timeout: return "WhatsApp send timed out"
            }
        }
    }

    // MARK: - Paths

    private var appFolder: URL {
        return StoragePaths.dataRoot
    }
    private var bridgeDirectory: URL { appFolder.appendingPathComponent("whatsapp-bridge", isDirectory: true) }
    private var authDirectory: URL { bridgeDirectory.appendingPathComponent("auth", isDirectory: true) }
    private var mediaDirectory: URL { bridgeDirectory.appendingPathComponent("media", isDirectory: true) }

    private static func resolveBinary(_ name: String) -> String? {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "\(NSHomeDirectory())/.local/bin/\(name)",
            "/usr/bin/\(name)"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    // MARK: - Lifecycle

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledDefaultsKey) }
    }

    func startIfEnabled() async {
        guard isEnabled else { return }
        let phone = (KeychainHelper.load(key: KeychainHelper.whatsappOwnerPhoneKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phone.isEmpty else {
            state = .failed("Owner phone number not configured")
            return
        }
        await start(ownerPhone: phone)
    }

    func start(ownerPhone: String) async {
        guard process == nil else { return }
        intentionallyStopped = false
        state = .starting
        qrString = nil

        guard let nodePath = Self.resolveBinary("node") else {
            state = .failed("Node.js not found (looked in /opt/homebrew/bin, /usr/local/bin, ~/.local/bin, /usr/bin). Install it from the onboarding browser step or with: brew install node")
            return
        }

        do {
            try await deployBridgeIfNeeded(nodePath: nodePath)
        } catch {
            state = .failed("Bridge install failed: \(error.localizedDescription)")
            return
        }

        let proc = Process()
        // Through the setsid trampoline with umask 077: the bridge writes
        // auth/media/session files under the data root and must create
        // them owner-only (the startup sweep only runs at start).
        let launch = BashTools.detachedInvocation(
            executable: nodePath, arguments: [bridgeDirectory.appendingPathComponent("index.js").path])
        proc.executableURL = URL(fileURLWithPath: launch.executable)
        proc.arguments = launch.arguments
        proc.currentDirectoryURL = bridgeDirectory
        var env = ProcessInfo.processInfo.environment
        env["BRIGLIA_CHILD_UMASK"] = "077"
        env["WA_AUTH_DIR"] = authDirectory.path
        env["WA_MEDIA_DIR"] = mediaDirectory.path
        env["WA_OWNER_PHONE"] = ownerPhone
        proc.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.consumeStdout(data)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastStderrTail = String((self.lastStderrTail + text).suffix(4000))
            }
        }

        proc.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            Task { @MainActor [weak self] in
                self?.handleProcessExit(status: status)
            }
        }

        do {
            try proc.run()
        } catch {
            state = .failed("Could not launch bridge: \(error.localizedDescription)")
            return
        }

        process = proc
        stdinPipe = stdin
        print("[WhatsAppChannelService] Bridge started (pid \(proc.processIdentifier))")
    }

    func stop() {
        intentionallyStopped = true
        teardownProcess()
        state = .disabled
        qrString = nil
    }

    /// Unlink the WhatsApp session entirely: tell the bridge to log out (which
    /// clears credentials), then stop. The next start shows a fresh QR.
    func logoutAndStop() async {
        if process != nil {
            try? sendCommand(["type": "logout"], expectAck: nil)
            // Give the bridge a moment to log out and clear its auth state.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        stop()
        try? FileManager.default.removeItem(at: authDirectory)
    }

    private func teardownProcess() {
        guard let proc = process else { return }
        process = nil
        stdinPipe = nil
        proc.terminationHandler = nil
        (proc.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (proc.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if proc.isRunning {
            proc.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
            }
        }
        for (_, continuation) in pendingAcks {
            continuation.resume(throwing: WhatsAppError.notConnected)
        }
        pendingAcks.removeAll()
        stdoutBuffer.removeAll()
    }

    private func handleProcessExit(status: Int32) {
        guard process != nil else { return } // already torn down deliberately
        process = nil
        stdinPipe = nil
        for (_, continuation) in pendingAcks {
            continuation.resume(throwing: WhatsAppError.notConnected)
        }
        pendingAcks.removeAll()

        guard !intentionallyStopped else { return }
        print("[WhatsAppChannelService] Bridge exited (status \(status)). stderr tail: \(lastStderrTail.suffix(500))")
        restartAttempts += 1
        if restartAttempts <= 5 {
            state = .disconnected(detail: "bridge exited, restarting…")
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await self?.startIfEnabled()
            }
        } else {
            let reason = "Bridge keeps crashing (status \(status)). Check Node install; last stderr: \(lastStderrTail.suffix(300))"
            state = .failed(reason)
            // The failure string above lives only in the Mac's Settings pane —
            // a remote user just experiences WhatsApp going permanently deaf.
            // Surface it through the maintenance alert center (deliverable via
            // Telegram, which is typically still up in this scenario).
            Task {
                await MaintenanceAlertCenter.shared.reportFailure(
                    .whatsappBridge,
                    error: "bridge crashed \(restartAttempts) times, giving up (exit status \(status))",
                    deterministic: true
                )
            }
        }
    }

    // MARK: - Bridge deployment

    /// Copy the bundled bridge into Application Support and install npm deps.
    /// index.js/package.json are refreshed on every start (cheap, keeps the
    /// deployed bridge in sync with the app build); node_modules is reinstalled
    /// only when missing or when package.json changed.
    private func deployBridgeIfNeeded(nodePath: String) async throws {
        let fm = FileManager.default
        try PrivateStorage.ensureDirectory(bridgeDirectory)
        try PrivateStorage.ensureDirectory(authDirectory)
        try PrivateStorage.ensureDirectory(mediaDirectory)

        // Ships inside the app bundle at Contents/Resources/WhatsAppBridge/
        // (same folder-reference mechanism as BundledSkills).
        guard let resourceURL = Bundle.module.resourceURL else {
            throw WhatsAppError.bridgeMissing("app bundle has no resource directory")
        }
        let bundled = resourceURL.appendingPathComponent("WhatsAppBridge", isDirectory: true)
        guard fm.fileExists(atPath: bundled.appendingPathComponent("index.js").path) else {
            throw WhatsAppError.bridgeMissing("WhatsAppBridge resources not found in app bundle")
        }

        let deployedPackageJSON = bridgeDirectory.appendingPathComponent("package.json")
        let bundledPackageJSON = bundled.appendingPathComponent("package.json")
        let packageChanged: Bool
        if let old = try? Data(contentsOf: deployedPackageJSON),
           let new = try? Data(contentsOf: bundledPackageJSON) {
            packageChanged = old != new
        } else {
            packageChanged = true
        }

        try Self.installBundledFiles(from: bundled, into: bridgeDirectory)

        let nodeModules = bridgeDirectory.appendingPathComponent("node_modules")
        if packageChanged || !fm.fileExists(atPath: nodeModules.path) {
            state = .installing
            try await runNpmInstall(nodePath: nodePath)
        }
    }

    /// Copy the bridge's bundled sources into the deployed directory as
    /// owner-only regular files (the bundle's copies are 0644 and a plain
    /// copyItem would carry that mode into the data root).
    nonisolated static func installBundledFiles(from bundled: URL, into directory: URL) throws {
        for file in ["index.js", "package.json"] {
            let data = try Data(contentsOf: bundled.appendingPathComponent(file))
            try PrivateStorage.writeAtomically(data, to: directory.appendingPathComponent(file))
        }
    }

    private func runNpmInstall(nodePath: String) async throws {
        // npm lives next to node in every standard install.
        let npmPath = URL(fileURLWithPath: nodePath).deletingLastPathComponent()
            .appendingPathComponent("npm").path
        guard FileManager.default.isExecutableFile(atPath: npmPath) else {
            throw WhatsAppError.bridgeMissing("npm not found next to node at \(npmPath)")
        }

        let proc = Process()
        // umask 077 via the trampoline: node_modules/ lands under the data
        // root and stays in the sweep's scope (owner-only like everything
        // else there; npm's own 0755 on .bin scripts becomes 0700 — owner
        // exec is all the bridge needs).
        let launch = BashTools.detachedInvocation(
            executable: npmPath, arguments: ["install", "--omit=dev", "--no-audit", "--no-fund"])
        proc.executableURL = URL(fileURLWithPath: launch.executable)
        proc.arguments = launch.arguments
        proc.currentDirectoryURL = bridgeDirectory
        var env = ProcessInfo.processInfo.environment
        env["BRIGLIA_CHILD_UMASK"] = "077"
        let nodeDir = URL(fileURLWithPath: nodePath).deletingLastPathComponent().path
        env["PATH"] = "\(nodeDir):" + (env["PATH"] ?? "/usr/bin:/bin")
        proc.environment = env
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = out
        proc.standardInput = FileHandle.nullDevice

        let outputQueue = DispatchQueue(label: "com.permaevidence.briglia.whatsapp.npm-output")
        var outputTail = ""
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            outputQueue.sync {
                outputTail = String((outputTail + text).suffix(4000))
            }
        }

        let exitStream = AsyncStream<Int32> { continuation in
            proc.terminationHandler = {
                continuation.yield($0.terminationStatus)
                continuation.finish()
            }
        }

        let result: Int32 = try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Int32.self) { group in
                group.addTask {
                    var iterator = exitStream.makeAsyncIterator()
                    return await iterator.next() ?? -1
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 120_000_000_000)
                    if proc.isRunning {
                        proc.terminate()
                        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                            if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
                        }
                    }
                    throw WhatsAppError.timeout
                }

                try proc.run()
                guard let result = try await group.next() else {
                    throw WhatsAppError.timeout
                }
                group.cancelAll()
                return result
            }
        } onCancel: {
            if proc.isRunning { proc.terminate() }
        }

        proc.terminationHandler = nil
        out.fileHandleForReading.readabilityHandler = nil
        let remaining = out.fileHandleForReading.availableData
        if !remaining.isEmpty, let text = String(data: remaining, encoding: .utf8) {
            outputQueue.sync {
                outputTail = String((outputTail + text).suffix(4000))
            }
        }
        let output = outputQueue.sync { outputTail }

        guard result == 0 else {
            throw WhatsAppError.bridgeMissing("npm install failed (\(result)): \(output.suffix(400))")
        }
        print("[WhatsAppChannelService] npm install completed")
    }

    // MARK: - Stdout protocol

    private func consumeStdout(_ data: Data) {
        stdoutBuffer.append(data)
        while let newlineIndex = stdoutBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<newlineIndex)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newlineIndex)
            guard !lineData.isEmpty else { continue }
            handleBridgeLine(lineData)
        }
        // Guard against a runaway un-terminated line.
        if stdoutBuffer.count > 4_000_000 { stdoutBuffer.removeAll() }
    }

    private func handleBridgeLine(_ lineData: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let type = obj["type"] as? String else { return }

        switch type {
        case "status":
            let stateName = obj["state"] as? String ?? ""
            switch stateName {
            case "connecting":
                if state != .waitingForQR { state = .starting }
            case "qr":
                qrString = obj["qr"] as? String
                state = .waitingForQR
            case "connected":
                qrString = nil
                restartAttempts = 0
                state = .connected(me: obj["me"] as? String)
                Task { await MaintenanceAlertCenter.shared.reportSuccess(.whatsappBridge) }
            case "disconnected":
                state = .disconnected(detail: obj["detail"] as? String ?? "unknown")
            case "logged_out":
                qrString = nil
                state = .loggedOut
            default:
                break
            }
            DebugTelemetry.log(.pollTick, summary: "whatsapp status: \(stateName)")

        case "message":
            if let message = try? JSONDecoder().decode(WhatsAppInboundMessage.self, from: lineData) {
                inboundQueue.append(message)
            }

        case "result":
            guard let id = obj["id"] as? String,
                  let continuation = pendingAcks.removeValue(forKey: id) else { return }
            if obj["ok"] as? Bool == true {
                continuation.resume()
            } else {
                continuation.resume(throwing: WhatsAppError.sendFailed(obj["error"] as? String ?? "unknown"))
            }

        case "log":
            if let msg = obj["msg"] as? String {
                print("[WhatsAppBridge] \(msg)")
            }

        default:
            break
        }
    }

    /// Drain buffered inbound messages — called from ConversationManager's poll loop.
    func drainInboundMessages() -> [WhatsAppInboundMessage] {
        guard !inboundQueue.isEmpty else { return [] }
        let drained = inboundQueue
        inboundQueue.removeAll()
        return drained
    }

    // MARK: - Outbound commands

    private func sendCommand(_ command: [String: Any], expectAck id: String?) throws {
        guard let stdinPipe, let process, process.isRunning else {
            throw WhatsAppError.notConnected
        }
        var cmd = command
        if let id { cmd["id"] = id }
        var data = try JSONSerialization.data(withJSONObject: cmd)
        data.append(UInt8(ascii: "\n"))
        try stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    private func sendWithAck(_ command: [String: Any], timeoutSeconds: UInt64 = 30) async throws {
        guard state.isConnected else { throw WhatsAppError.notConnected }
        nextCommandId += 1
        let id = "c\(nextCommandId)"

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pendingAcks[id] = continuation
            do {
                try sendCommand(command, expectAck: id)
            } catch {
                pendingAcks.removeValue(forKey: id)
                continuation.resume(throwing: error)
                return
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                if let pending = self?.pendingAcks.removeValue(forKey: id) {
                    pending.resume(throwing: WhatsAppError.timeout)
                }
            }
        }
    }

    /// Write transient outbound payloads here so the bridge can read them by path.
    private func spoolOutbound(_ data: Data, suffix: String) throws -> URL {
        let url = mediaDirectory.appendingPathComponent("out_\(UUID().uuidString.prefix(8)).\(suffix)")
        try PrivateStorage.writeAtomically(data, to: url)
        return url
    }
}

// MARK: - ChatChannel conformance

extension WhatsAppChannelService: ChatChannel {
    nonisolated var kind: ChannelKind { .whatsapp }

    func sendText(chatId: String, text: String) async throws {
        // WhatsApp's practical per-message limit is ~65k chars — far above what
        // the agent produces (history cap is 4000), so no truncation here.
        try await sendWithAck(["type": "send_text", "to": chatId, "text": text])
    }

    func sendPhoto(chatId: String, imageData: Data, caption: String?, mimeType: String) async throws {
        let ext = mimeType.contains("png") ? "png" : "jpg"
        let url = try spoolOutbound(imageData, suffix: ext)
        defer { try? FileManager.default.removeItem(at: url) }
        var cmd: [String: Any] = ["type": "send_image", "to": chatId, "path": url.path]
        if let caption { cmd["caption"] = caption }
        try await sendWithAck(cmd, timeoutSeconds: 60)
    }

    func sendDocument(chatId: String, documentData: Data, filename: String, caption: String?, mimeType: String) async throws {
        let ext = URL(fileURLWithPath: filename).pathExtension
        let url = try spoolOutbound(documentData, suffix: ext.isEmpty ? "bin" : ext)
        defer { try? FileManager.default.removeItem(at: url) }
        var cmd: [String: Any] = [
            "type": "send_document",
            "to": chatId,
            "path": url.path,
            "filename": filename,
            "mimeType": mimeType
        ]
        if let caption { cmd["caption"] = caption }
        try await sendWithAck(cmd, timeoutSeconds: 120)
    }
}
