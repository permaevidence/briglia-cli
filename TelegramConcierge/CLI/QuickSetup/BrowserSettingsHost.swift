import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// A settings server lives in the conversation owner when one is running.
/// Otherwise this command holds the same exclusive lease until the server stops.
/// No competing daemon, restart, or release of the live owner's lease is needed.
@MainActor
final class BrowserSettingsHost {
    private static var shared: BrowserSettingsHost?
    let auth: QuickSetupWorkflow
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
        auth = try QuickSetupWorkflow(env: QuickSetupEnvironment(), runner: SetupJobRunner(secrets: [:]), resume: .fresh)
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

    static func runCommand() async throws {
        // No package manager, disk-install floor, or setup-completion writes.
        let acquired = InstanceLease.acquire(label: "browser settings")
        switch acquired {
        case .failure:
            do {
                let link = try await Task.detached { try requestRunningOwner() }.value
                printAndOpen(link)
                print("Settings are served by the running Briglia. The page expires after 30 minutes of inactivity.")
                return
            } catch {
                throw BrowserSettingsWorkflow.Invalid(text: "Could not open settings in the running Briglia: \(error.localizedDescription). Update the running process to this version, or stop it and run `briglia quicksetup` again.")
            }
        case .success(let lease):
            let host: BrowserSettingsHost
            do { host = try BrowserSettingsHost(manager: nil, lease: lease) }
            catch { lease.release(); throw error }
            shared = host; host.startTimer()
            let listener = EnterListener {
                Task { @MainActor in
                    _ = await host.auth.rotate()
                    await host.settings.cancelPendingLogin()
                    printAndOpen(await host.link())
                }
            }
            printAndOpen(await host.link())
            print("Press Enter for a new link. Ctrl-C closes settings. Saved changes are kept.")
            listener.start()
            let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            signal(SIGINT, SIG_IGN)
            signalSource.setEventHandler { Task { @MainActor in await host.stop() } }
            signalSource.resume()
            while !host.stopped { try? await Task.sleep(nanoseconds: 250_000_000) }
            listener.stop(); signalSource.cancel(); signal(SIGINT, SIG_DFL)
            print("Browser settings closed. Run `briglia` or `briglia daemon` to start the agent.")
        }
    }
    private static func printAndOpen(_ link: String) {
        print("\nBriglia settings: \(link)\n")
        QuickSetupSession.openBrowser(link)
    }
    nonisolated private static func requestRunningOwner() throws -> String {
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
        let data = try JSONSerialization.data(withJSONObject: ["type": "browser_settings", "ref": ref]) + Data([10])
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
