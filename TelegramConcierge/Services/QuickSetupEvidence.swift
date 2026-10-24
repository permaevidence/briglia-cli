import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Platform facts the desktop quick setup refuses on, verifies, and reports
/// in `setup-api status` (plan §3.1, §4.5–4.7, §6.2). Every reader here is
/// side-effect free; the mutating steps live in the workflow.
enum QuickSetupEvidence {
    /// Silent process runner for evidence probes. `ProcessRunner.runBlockingProcess`
    /// prints a diagnostic line to STDOUT on a non-zero exit — fatal for
    /// `setup-api status`, whose stdout must stay pure JSON (CI, 2026-09-04:
    /// `python3 -m pip --version` failing broke every status parse).
    static func quietRun(_ executable: String, _ args: [String], timeoutSeconds: Int = 20) -> (status: Int32, stdout: String, stderr: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return nil }
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter(); DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { process.terminate(); Thread.sleep(forTimeInterval: 0.2); if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        process.waitUntilExit()
        group.wait()
        return (process.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self))
    }

    // MARK: Disk floors (§3.1)

    struct DiskCheck: Equatable {
        var path: String
        var mount: String
        var freeBytes: Int64
        var floorBytes: Int64
        /// statvfs failed for this destination: never silently omitted.
        var unreadable = false
        var ok: Bool { !unreadable && freeBytes >= floorBytes }
    }

    /// Selftest seam: (path) → (deviceID, mount, freeBytes); nil = statvfs failed.
    nonisolated(unsafe) static var statvfsOverride: ((String) -> (device: UInt64, mount: String, free: Int64)?)?

    static let gb: Int64 = 1_000_000_000

    /// The destination filesystems and their floors for this platform.
    static func diskFloorTargets(brewPrefix: String?, packageCache: String?) -> [(path: String, floor: Int64)] {
        var targets: [(String, Int64)] = [(NSHomeDirectory(), 1 * gb)]
        #if os(macOS)
        if let brewPrefix { targets.append((brewPrefix, 3 * gb)) }
        targets.append(("/private/tmp", 2 * gb))
        #else
        targets.append(("/usr", Int64(2.5 * Double(gb))))
        if let packageCache { targets.append((packageCache, Int64(1.5 * Double(gb)))) }
        #endif
        return targets
    }

    /// statvfs per path, compared by device id: the same filesystem is
    /// counted once with summed floors.
    static func diskChecks(targets: [(path: String, floor: Int64)]) -> [DiskCheck] {
        struct Agg { var paths: [String]; var mount: String; var free: Int64; var floor: Int64 }
        var byDevice: [UInt64: Agg] = [:]
        var order: [UInt64] = []
        var unreadable: [DiskCheck] = []
        for (path, floor) in targets {
            guard let info = statInfo(path) else {
                unreadable.append(DiskCheck(path: path, mount: "?", freeBytes: 0, floorBytes: floor, unreadable: true))
                continue
            }
            if var agg = byDevice[info.device] {
                agg.paths.append(path)
                agg.floor += floor
                byDevice[info.device] = agg
            } else {
                byDevice[info.device] = Agg(paths: [path], mount: info.mount, free: info.free, floor: floor)
                order.append(info.device)
            }
        }
        return unreadable + order.compactMap { dev in
            guard let agg = byDevice[dev] else { return nil }
            return DiskCheck(path: agg.paths.joined(separator: ", "), mount: agg.mount, freeBytes: agg.free, floorBytes: agg.floor)
        }
    }

    private static func statInfo(_ path: String) -> (device: UInt64, mount: String, free: Int64)? {
        if let statvfsOverride { return statvfsOverride(path) }
        // Walk up to the nearest existing ancestor (a package cache may not exist yet).
        var probe = path
        var st = stat()
        while stat(probe, &st) != 0 {
            let parent = URL(fileURLWithPath: probe).deletingLastPathComponent().path
            if parent == probe { return nil }
            probe = parent
        }
        var vfs = statvfs()
        guard statvfs(probe, &vfs) == 0 else { return nil }
        let free = Int64(vfs.f_bavail) * Int64(vfs.f_frsize)
        return (UInt64(st.st_dev), mountPoint(of: probe) ?? probe, free)
    }

    private static func mountPoint(of path: String) -> String? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        let dev = st.st_dev
        var current = path
        while true {
            let parent = URL(fileURLWithPath: current).deletingLastPathComponent().path
            if parent == current { return current }
            var pst = stat()
            guard stat(parent, &pst) == 0 else { return current }
            if pst.st_dev != dev { return current }
            current = parent
        }
    }

    static func formatGB(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / Double(gb))
    }

    // MARK: Python / pip

    struct PythonStatus: Equatable { var present: Bool; var pipOK: Bool }

    static func pythonStatus() -> PythonStatus {
        guard let python = ToolchainService.python3Path() else { return PythonStatus(present: false, pipOK: false) }
        let r = quietRun(python, ["-m", "pip", "--version"], timeoutSeconds: 20)
        return PythonStatus(present: true, pipOK: r?.status == 0)
    }

    // MARK: Linux package manager / cache

    #if os(Linux)
    static func packageCacheDirectory(manager: String) -> String {
        switch manager {
        case "apt-get": return "/var/cache/apt/archives"
        case "dnf": return "/var/cache/dnf"
        case "pacman": return "/var/cache/pacman/pkg"
        default: return "/var/cache"
        }
    }
    #endif

    // MARK: Service verification (Linux, §4.5 (a)–(d))

    #if os(Linux)
    struct ServiceEvidence: Equatable {
        var active: Bool
        var linger: Bool
        var handshake: Bool
        var stable: Bool
        var detail: String
        var ok: Bool { active && linger && handshake && stable }
    }

    nonisolated(unsafe) static var stabilityWindow: TimeInterval = 20
    /// Selftest seams.
    nonisolated(unsafe) static var systemctlShowOverride: (() -> String)?
    nonisolated(unsafe) static var lingerOverride: (() -> Bool)?
    nonisolated(unsafe) static var isActiveOverride: (() -> String)?

    static func serviceEvidence() async -> ServiceEvidence {
        let active = (isActiveOverride?() ?? AgentServiceSupport.run("systemctl", ["--user", "is-active", AgentServiceSupport.userUnitName]).output) == "active"
        let linger = lingerOverride?() ?? AgentServiceSupport.lingerEnabled()
        guard active else { return ServiceEvidence(active: false, linger: linger, handshake: false, stable: false, detail: "service is not active") }
        guard linger else { return ServiceEvidence(active: true, linger: false, handshake: false, stable: false, detail: "start at boot not confirmed enabled (linger)") }
        guard socketHandshake() else { return ServiceEvidence(active: true, linger: true, handshake: false, stable: false, detail: "the app socket did not answer the hello (the poller is not up)") }
        let before = systemctlShowOverride?() ?? AgentServiceSupport.run("systemctl", ["--user", "show", "-p", "NRestarts", "-p", "ActiveEnterTimestamp", AgentServiceSupport.userUnitName]).output
        try? await Task.sleep(nanoseconds: UInt64(stabilityWindow * 1_000_000_000))
        let after = systemctlShowOverride?() ?? AgentServiceSupport.run("systemctl", ["--user", "show", "-p", "NRestarts", "-p", "ActiveEnterTimestamp", AgentServiceSupport.userUnitName]).output
        guard before == after else { return ServiceEvidence(active: true, linger: true, handshake: true, stable: false, detail: "the service restarted within the stability window (\(after))") }
        guard socketHandshake() else { return ServiceEvidence(active: true, linger: true, handshake: true, stable: false, detail: "the app socket stopped answering during the stability window") }
        return ServiceEvidence(active: true, linger: true, handshake: true, stable: true, detail: "active, starts at boot, socket answered, stable for \(Int(stabilityWindow)) s")
    }
    #endif

    /// Connect to `app-chat.sock` and read the `hello` frame.
    nonisolated(unsafe) static var socketHandshakeOverride: (() -> Bool)?
    static func socketHandshake() -> Bool {
        if let socketHandshakeOverride { return socketHandshakeOverride() }
        let path = AppChatSocketServer.socketURL.path
        var addr = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        let bytes = path.utf8CString
        guard bytes.count <= capacity else { return false }
        #if canImport(Glibc)
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { return false }
        defer { close(fd) }
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in bytes.withUnsafeBytes { src in dst.copyBytes(from: src.prefix(capacity)) } }
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard rc == 0 else { return false }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buf = [UInt8](repeating: 0, count: 4096)
        var got = Data()
        while got.count < 4096 {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            got.append(contentsOf: buf[0..<n])
            if got.contains(0x0A) { break }
        }
        guard let line = String(data: got, encoding: .utf8)?.split(separator: "\n").first,
              let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return false }
        let type = (json["type"] as? String) ?? (json["event"] as? String) ?? ""
        let version = (json["protocolVersion"] as? Int) ?? (json["protocol"] as? Int) ?? 0
        return type == "hello" && version == AppChatSocketServer.protocolVersion
    }

    // MARK: Status block (§6.2)

    static func statusAdditions() -> [String: Any] {
        var out: [String: Any] = [:]
        let py = pythonStatus()
        out["python3"] = ["present": py.present, "pip_ok": py.pipOK]
        #if os(macOS)
        out["permissions"] = [
            "full_disk_access": PermissionsService.fullDiskAccessGranted(),
            "terminal_app": terminalAppName(),
            "system_sleep_ac_minutes": systemSleepMinutesAC() as Any,
            "keep_awake_assertion_held": KeepAwake.isHeld,
        ] as [String: Any]
        let brew = ToolchainService.brewPath()
        out["homebrew"] = ["present": brew != nil]
        let prefix = brew.map { URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent().path }
        out["disk"] = diskChecks(targets: diskFloorTargets(brewPrefix: prefix, packageCache: nil)).map(diskDict)
        #else
        let verdict = PermissionsService.autoSuspendVerdict()
        var keep: [String: Any] = ["verdict": verdict.key]
        switch verdict {
        case .noDetectedIdleAutoSuspend(let ev): keep["evidence"] = ev.description
        case .maySuspend(let reason): keep["reason"] = reason
        case .sleepImpossible: keep["evidence"] = "all sleep targets masked"
        }
        let facts = AutoSuspendCensus.collectFacts()
        keep["lid_present"] = facts.lidPresent ?? false
        keep["battery_present"] = facts.internalBatteryPresent ?? false
        out["keep_awake"] = keep
        if let manager = ToolchainService.linuxPackageManager() {
            out["package_manager"] = ["name": manager.name, "install_args": manager.installArgs] as [String: Any]
            out["disk"] = diskChecks(targets: diskFloorTargets(brewPrefix: nil, packageCache: packageCacheDirectory(manager: manager.name))).map(diskDict)
        } else {
            out["disk"] = diskChecks(targets: diskFloorTargets(brewPrefix: nil, packageCache: nil)).map(diskDict)
        }
        #endif
        let tc = ToolchainService.desktopStatus()
        out["toolchain_desktop"] = [
            "doctor_ran": tc.doctorRan, "missing": tc.missing, "libreoffice": tc.libreOffice,
            "mandatory_missing": tc.mandatoryMissing, "complete": tc.complete,
        ] as [String: Any]
        return out
    }

    private static func diskDict(_ c: DiskCheck) -> [String: Any] {
        ["path": c.path, "mount": c.mount, "free_bytes": c.freeBytes, "floor_bytes": c.floorBytes, "ok": c.ok, "unreadable": c.unreadable]
    }

    #if os(macOS)
    static func terminalAppName() -> String {
        switch ProcessInfo.processInfo.environment["TERM_PROGRAM"] ?? "" {
        case "Apple_Terminal": return "Terminal"
        case "iTerm.app": return "iTerm"
        case "WarpTerminal": return "Warp"
        case "vscode": return "Visual Studio Code"
        case "Hyper": return "Hyper"
        case "ghostty": return "Ghostty"
        case "WezTerm": return "WezTerm"
        case "kitty": return "kitty"
        case "Alacritty": return "Alacritty"
        default: return "your terminal app"
        }
    }

    /// `pmset -g custom` → `sleep` on AC (informational only).
    static func systemSleepMinutesAC() -> Int? {
        guard let r = quietRun("/usr/bin/pmset", ["-g", "custom"], timeoutSeconds: 10), r.status == 0 else { return nil }
        let out = r.stdout
        var inAC = true
        for line in out.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasSuffix("Power:") { inAC = t.hasPrefix("AC"); continue }
            let parts = t.split(separator: " ", omittingEmptySubsequences: true)
            if inAC, parts.count == 2, parts[0] == "sleep", let v = Int(parts[1]) { return v }
        }
        return nil
    }
    #endif
}

extension AutoSuspendCensus.Verdict.Evidence: CustomStringConvertible {
    var description: String {
        switch self {
        case .headless(let d): return "headless: \(d)"
        case .gnomeNothing(let lid): return "GNOME sleep-inactive = nothing\(lid ? " (lid present)" : "")"
        }
    }
}
