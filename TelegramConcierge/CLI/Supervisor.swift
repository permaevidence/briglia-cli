import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// `briglia daemon --all` (MULTI_ASSISTANT_PLAN §4.3): one terminal window
/// runs every assistant with `autostart`.
///
/// - `briglia-shared/supervisor.lock` (non-blocking): one supervisor.
/// - A profile whose assistant lease is held by someone else (a terminal
///   chat, systemd) is "running elsewhere" and left alone.
/// - Children: `briglia __setsid-exec <briglia> --profile <n> daemon` with
///   `BRIGLIA_SUPERVISED=1` (own session and process group). Each child writes
///   its own `<data root>/logs/daemon.log`; the supervisor tails those files
///   with a `[Name]` prefix, so losing the supervisor never loses a log.
/// - Exit 0 = stopped on purpose (SIGTERM, `profiles stop`): not restarted.
///   Anything else: restart after 1 s, 5 s, 30 s, 5 min; 5 failures within
///   10 minutes park that assistant.
/// - SIGINT/SIGTERM: SIGTERM to every child's group, up to 30 s, then
///   SIGKILL the group, exit.
/// - Never re-execs, loads no resources, holds no profile state, never runs
///   the leftover-child sweep.
final class Supervisor {
    struct Settings {
        var registryPaths: AssistantRegistry.Paths = .live
        var executable: URL = UpgradeService.executableURL
        var backoff: [TimeInterval] = Supervisor.defaultBackoff
        var parkAfter = 5
        var parkWindow: TimeInterval = 600
        var stopGrace: TimeInterval = 30
        var tick: TimeInterval = 0.5
        var output: (String) -> Void = { print($0); fflush(stdout) }
    }

    static var defaultBackoff: [TimeInterval] {
        if adaCLIVersion.hasSuffix("-dev"), let raw = ProcessInfo.processInfo.environment["BRIGLIA_TEST_SUPERVISOR_BACKOFF"] {
            let v = raw.split(separator: ",").compactMap { Double($0) }
            if !v.isEmpty { return v }
        }
        return [1, 5, 30, 300]
    }

    static let supervisedKey = "BRIGLIA_SUPERVISED"

    final class Child {
        let profile: String
        var display: String
        var process: Process?
        var logURL: URL
        var logOffset: UInt64 = 0
        var partial = Data()
        var failures: [Date] = []
        var nextStart: Date? = Date()
        var state: String = "starting"   // running | stopped | parked | elsewhere | waiting
        init(profile: String, display: String, logURL: URL) { self.profile = profile; self.display = display; self.logURL = logURL }
    }

    let settings: Settings
    private var children: [String: Child] = [:]
    private var stopping = false
    private var lock: ProfileFileLock?

    init(settings: Settings = Settings()) { self.settings = settings }

    enum Start: Equatable { case ok, refused(String) }

    func acquire() -> Start {
        do { try PrivateStorage.ensureDirectory(settings.registryPaths.root, mode: 0o700) } catch { return .refused("\(error)") }
        switch ProfileFileLock.take(settings.registryPaths.root.appendingPathComponent("supervisor.lock")) {
        case .acquired(let l): lock = l; return .ok
        case .busy: return .refused("Another `briglia daemon --all` is already running on this computer.")
        case .failed(let why): return .refused(why)
        }
    }

    static func logURL(profile: String) -> URL {
        let root = profile == AssistantProfile.defaultName ? MachinePaths.defaultDataRoot() : AssistantProfile.extraDataRoot(profile)
        return root.appendingPathComponent("logs", isDirectory: true).appendingPathComponent("daemon.log")
    }

    func records() -> [AssistantRegistry.Record] {
        guard let doc = (try? AssistantRegistry.read(settings.registryPaths)) ?? nil else {
            return [AssistantRegistry.newRecord(name: AssistantProfile.defaultName, displayName: "Bree")]
        }
        return doc.records.filter { $0.state == "active" && $0.autostart }
    }

    func leaseDirectory(_ r: AssistantRegistry.Record) -> URL {
        r.name == AssistantProfile.defaultName ? MemberLeases.defaultDirectory()
            : settings.registryPaths.root.appendingPathComponent("members/\(r.name)/\(r.generation)", isDirectory: true)
    }

    /// One pass: reconcile the registry with the children, restart what
    /// crashed (with backoff), tail the logs.
    func tick(now: Date = Date()) {
        for r in records() {
            let child = children[r.name] ?? {
                let c = Child(profile: r.name, display: r.displayName, logURL: Self.logURL(profile: r.name))
                children[r.name] = c
                return c
            }()
            child.display = r.displayName
            if let p = child.process {
                if p.isRunning { continue }
                child.process = nil
                let status = p.terminationStatus
                let byOurSignal = p.terminationReason == .uncaughtSignal && stopping
                if status == 0 || byOurSignal {
                    child.state = "stopped"
                    child.nextStart = nil
                    say(child, "stopped")
                    continue
                }
                child.failures = child.failures.filter { now.timeIntervalSince($0) < settings.parkWindow } + [now]
                if child.failures.count >= settings.parkAfter {
                    child.state = "parked"
                    child.nextStart = nil
                    say(child, "stopped after \(child.failures.count) crashes in \(Int(settings.parkWindow / 60)) minutes — parked. Check its log: \(child.logURL.path)")
                    continue
                }
                let delay = settings.backoff[min(child.failures.count - 1, settings.backoff.count - 1)]
                child.nextStart = now.addingTimeInterval(delay)
                child.state = "waiting"
                say(child, "exited (status \(status)); restarting in \(Int(delay)) s")
                continue
            }
            guard let due = child.nextStart, due <= now, !stopping else { continue }
            if !MemberLeases.users(leaseDirectory(r), assistantsOnly: true).isEmpty {
                if child.state != "elsewhere" { say(child, "running elsewhere (a terminal or a service) — left alone") }
                child.state = "elsewhere"
                child.nextStart = now.addingTimeInterval(10)
                continue
            }
            spawn(child)
        }
        for c in children.values { drainLog(c) }
    }

    func spawn(_ child: Child) {
        let p = Process()
        p.executableURL = settings.executable
        p.arguments = ["__setsid-exec", "--", settings.executable.path, "--profile", child.profile, "daemon"]
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: AssistantProfile.environmentKey)
        env[Self.supervisedKey] = "1"
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        if let size = try? FileManager.default.attributesOfItem(atPath: child.logURL.path)[.size] as? NSNumber {
            child.logOffset = size.uint64Value
        } else {
            child.logOffset = 0
        }
        do {
            try p.run()
            child.process = p
            child.state = "running"
            child.nextStart = nil
            say(child, "started (pid \(p.processIdentifier))")
        } catch {
            child.nextStart = Date().addingTimeInterval(settings.backoff.last ?? 300)
            say(child, "could not start: \(error)")
        }
    }

    func drainLog(_ child: Child) {
        guard let h = try? FileHandle(forReadingFrom: child.logURL) else { return }
        defer { try? h.close() }
        let end = (try? h.seekToEnd()) ?? 0
        if end < child.logOffset { child.logOffset = 0 }       // rotated
        guard end > child.logOffset else { return }
        try? h.seek(toOffset: child.logOffset)
        let data = (try? h.read(upToCount: Int(min(end - child.logOffset, 1 << 20)))) ?? Data()
        child.logOffset += UInt64(data.count)
        child.partial.append(data)
        while let nl = child.partial.firstIndex(of: 0x0a) {
            let line = String(decoding: child.partial[child.partial.startIndex..<nl], as: UTF8.self)
            child.partial.removeSubrange(child.partial.startIndex...nl)
            settings.output("[\(child.display)] \(line)")
        }
    }

    private func say(_ child: Child, _ text: String) { settings.output("[\(child.display)] · \(text)") }

    /// SIGTERM every child's group, wait up to `stopGrace`, SIGKILL the rest.
    func stopAll() {
        stopping = true
        let running = children.values.compactMap { $0.process }.filter { $0.isRunning }
        for p in running { kill(-p.processIdentifier, SIGTERM); kill(p.processIdentifier, SIGTERM) }
        let deadline = Date().addingTimeInterval(settings.stopGrace)
        while Date() < deadline, running.contains(where: { $0.isRunning }) { Thread.sleep(forTimeInterval: 0.1) }
        for p in running where p.isRunning { kill(-p.processIdentifier, SIGKILL); kill(p.processIdentifier, SIGKILL) }
        for c in children.values { drainLog(c) }
    }

    var snapshot: [String: String] { children.mapValues { $0.state } }

    /// The foreground loop of `briglia daemon --all`.
    func runForever() -> Never {
        settings.output("Briglia supervisor — every assistant on this computer. Ctrl-C stops them all.")
        let queue = DispatchQueue(label: "briglia.supervisor")
        var sources: [DispatchSourceSignal] = []
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            s.setEventHandler { [self] in
                settings.output("Stopping every assistant…")
                stopAll()
                exit(0)
            }
            s.resume()
            sources.append(s)
        }
        while true {
            withExtendedLifetime(sources) { queue.sync { tick() } }
            Thread.sleep(forTimeInterval: settings.tick)
        }
    }
}

/// A supervised daemon writes its own log file (stdout and stderr), so the
/// log survives the supervisor (§4.3).
enum SupervisedLog {
    static func redirectIfSupervised() {
        guard ProcessInfo.processInfo.environment[Supervisor.supervisedKey] == "1" else { return }
        let url = StoragePaths.dataRoot.appendingPathComponent("logs", isDirectory: true).appendingPathComponent("daemon.log")
        try? PrivateStorage.ensureDirectory(url.deletingLastPathComponent(), mode: 0o700)
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue, size > 10 << 20 {
            try? FileManager.default.removeItem(atPath: url.path + ".1")
            try? FileManager.default.moveItem(atPath: url.path, toPath: url.path + ".1")
        }
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        fflush(stdout); fflush(stderr)
        dup2(fd, STDOUT_FILENO)
        dup2(fd, STDERR_FILENO)
        close(fd)
        setvbuf(stdout, nil, _IOLBF, 0)
    }
}
