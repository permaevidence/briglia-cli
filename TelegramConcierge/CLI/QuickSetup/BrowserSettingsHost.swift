import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Browser settings served by the running Briglia (app-socket request
/// `browser_settings`, kept for older clients; `briglia menu` is the
/// settings page now). Its offline mode — `briglia quicksetup` on a set-up
/// install — was retired in 0.2.67 with the browser Quick Setup.
@MainActor
final class BrowserSettingsHost {
    private static var shared: BrowserSettingsHost?
    let auth: PageAuthorizer
    let settings: BrowserSettingsWorkflow
    let server: QuickSetupHTTPServer
    private var lease: InstanceLease?
    private var timer: Task<Void, Never>?
    private var stopping = false
    private(set) var stopped = false

    init(manager: ConversationManager?, lease: InstanceLease?) throws {
        self.lease = lease
        guard let directory = QuickSetupPreflight.pageDirectory(),
              ["settings.html", "settings.js"].allSatisfy({ FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }) else {
            throw BrowserSettingsWorkflow.Invalid(text: "Browser settings resources are missing. Reinstall Briglia.")
        }
        auth = try PageAuthorizer(runner: SetupJobRunner(secrets: [:]))
        var env = BrowserSettingsWorkflow.Environment()
        if let manager {
            env.running = true
            env.beginMutation = { [weak manager] in await manager?.beginBrowserSettingsMutation() ?? false }
            env.endMutation = { [weak manager] in manager?.endBrowserSettingsMutation() }
            env.reload = { [weak manager] in await manager?.reloadBrowserSettings() }
        }
        settings = BrowserSettingsWorkflow(auth: auth, env: env)
        let box = QuickSetupSession.PortBox()
        let router = QuickSetupRouter(workflow: auth, pageDirectory: directory) { box.port }
        router.settings = settings
        server = QuickSetupHTTPServer { await router.handle($0) }
        try server.start()
        box.port = server.port
    }
    private func startTimer() {
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if Date().timeIntervalSince(self.server.lastActivity) > 1800 { await self.stop(); return }
            }
        }
    }
    static func open(manager: ConversationManager) async throws -> String {
        if let host = shared, !host.stopped {
            guard !host.stopping else { throw BrowserSettingsWorkflow.Invalid(text: "Settings are closing. Retry in a moment.") }
            _ = await host.auth.rotate()
            await host.settings.cancelPendingLogin()
            return await host.link()
        }
        let host = try BrowserSettingsHost(manager: manager, lease: nil)
        shared = host; host.startTimer()
        return await host.link()
    }
    private func link() async -> String {
        "http://127.0.0.1:\(server.port)/start?t=\(await auth.launchToken)"
    }
    func stop() async {
        if stopped { return }
        if stopping {
            // A signal, idle expiry and normal quit may converge here. Every
            // caller must await the same settlement before releasing a lease.
            while !stopped { try? await Task.sleep(nanoseconds: 50_000_000) }
            return
        }
        stopping = true
        server.stop()
        _ = await auth.rotate()
        // Rotation's ordinary wait is bounded; closing must not release an
        // offline instance lease while an old callback could still write.
        while await auth.inFlightOperations > 0 { try? await Task.sleep(nanoseconds: 50_000_000) }
        await settings.cancelPendingLogin()
        timer?.cancel(); timer = nil
        lease?.release(); lease = nil
        stopped = true
        if Self.shared === self { Self.shared = nil }
    }
    static func stopShared() async { await shared?.stop() }

    /// Asks the running Briglia (over the app socket) to open a local page:
    /// `browser_settings` (quick setup's settings) or `menu` (the live hub).
    nonisolated static func requestRunningOwner(type: String = "browser_settings") throws -> String {
        struct Failure: LocalizedError { var errorDescription: String? { "The local agent socket is unavailable or does not support browser settings" } }
        var addr = sockaddr_un()
        let path = AppChatSocketServer.socketURL.path.utf8CString
        guard path.count <= MemoryLayout.size(ofValue: addr.sun_path) else { throw Failure() }
        #if canImport(Glibc)
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw Failure() }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 45, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in path.withUnsafeBytes { dst.copyBytes(from: $0) } }
        let connected = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard connected == 0, AppChatSocketServer.peerUID(of: fd) == getuid() else { throw Failure() }
        let ref = UUID().uuidString
        let data = try JSONSerialization.data(withJSONObject: ["type": type, "ref": ref]) + Data([10])
        try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: data)
        var buffer = Data(); var chunk = [UInt8](repeating: 0, count: 8192)
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { throw Failure() }
            buffer.append(contentsOf: chunk.prefix(n))
            guard buffer.count < 8 * 1024 * 1024 else { throw Failure() }
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], object["ref"] as? String == ref else { continue }
                guard object["type"] as? String == "ack", let link = object["url"] as? String,
                      let url = URL(string: link), url.scheme == "http", url.host == "127.0.0.1", url.port != nil,
                      url.path == "/start", url.user == nil, url.password == nil else { throw Failure() }
                return link
            }
        }
        throw Failure()
    }
}
