import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

extension ProfilesCommand {
    /// `briglia profiles remove <name>` (MULTI_ASSISTANT_PLAN §5.7): the typed
    /// confirmation and the Mind-export offer come first, outside every lock;
    /// then `removing` is published and the profile's leases probed ("publish,
    /// then look"); any user → refused and restored. User folders (home,
    /// worktrees) are never deleted.
    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "remove", abstract: "Remove an assistant (asks first; offers a memory export).")

        @Argument(help: "The assistant's profile id.") var name: String
        @Flag(name: .customLong("yes"), help: "Skip the typed confirmation.") var yes = false
        @Flag(name: .customLong("no-export"), help: "Do not offer a memory export first.") var noExport = false
        @Option(name: .customLong("export-to"), help: "Export the assistant's memory to this folder first (no question asked).") var exportTo: String?

        func run() async throws {
            try ProfilesCommand.requireExperimental()
            try ProfilesCommand.requireDefault()
            guard name != AssistantProfile.defaultName else {
                print("✖ The default assistant cannot be removed.")
                throw ExitCode(2)
            }
            guard let record = (try? AssistantRegistry.read(.live))??.record(name) else {
                print("✖ There is no assistant ‘\(name)’ on this computer.")
                throw ExitCode(2)
            }
            let display = record.displayName
            if !yes {
                print("This removes the assistant ‘\(display)’: its memory, reminders, watchers, settings and keys. Its home folder and any git worktrees are kept.")
                print("Type its id (\(name)) to confirm: ", terminator: "")
                fflush(stdout)
                guard (readLine() ?? "").trimmingCharacters(in: .whitespaces) == name else {
                    print("Cancelled — nothing was removed.")
                    return
                }
            }
            var exportDir = exportTo
            if exportDir == nil, !noExport, !yes {
                print("Export ‘\(display)’'s memory first (a .mind file on your Desktop)? [Y/n] ", terminator: "")
                fflush(stdout)
                let answer = (readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased()
                if answer.isEmpty || answer == "y" || answer == "yes" {
                    exportDir = ConversationManager.mindExportDestinationDirectory().path
                }
            }
            if let exportDir {
                do {
                    let path = try ProfileLifecycle.exportMind(profile: name, directory: URL(fileURLWithPath: exportDir))
                    print("✔ Memory exported: \(path)")
                } catch {
                    print("✖ The memory export failed (\(error)); nothing was removed. Use --no-export to remove without it.")
                    throw ExitCode(1)
                }
            }
            do {
                let kept = try ProfileLifecycle.remove(name: name, confirmedGeneration: record.generation)
                print("✔ Removed the assistant ‘\(display)’.")
                for path in kept { print("  Kept (your files): \(path)") }
            } catch {
                print("✖ \(error)")
                throw ExitCode(1)
            }
        }
    }

    /// `briglia profiles stop <name>`: SIGTERM to the assistant processes of
    /// that profile, each validated against its lease (pid + start time +
    /// executable, lease still held) — never a guess from a pid alone.
    struct Stop: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "stop", abstract: "Stop a running assistant.")

        @Argument(help: "The assistant's profile id (default for the first assistant).") var name: String

        func run() throws {
            try ProfilesCommand.requireExperimental()
            try ProfilesCommand.requireDefault()
            var wait: TimeInterval = 30
            if adaCLIVersion.hasSuffix("-dev"), let v = Double(ProcessInfo.processInfo.environment["BRIGLIA_TEST_STOP_WAIT"] ?? "") { wait = v }
            let stopped = ProfileLifecycle.stop(name: name, wait: wait)
            switch stopped {
            case .notRunning: print("‘\(name)’ is not running.")
            case .stopped(let pids): print("✔ Stopped ‘\(name)’ (pid \(pids.map(String.init).joined(separator: ", "))).")
            case .failed(let why): print("✖ \(why)"); throw ExitCode(1)
            }
        }
    }
}

/// Removal and stop, separated from the command so the selftest drives them
/// against scratch roots.
enum ProfileLifecycle {
    struct LifecycleError: Error, CustomStringConvertible { let description: String; init(_ d: String) { description = d } }

    // MARK: Mind export (offline)

    /// Run `briglia --profile <n> __mind-export --to <dir>` (the profile's own
    /// process writes the archive; it refuses while the assistant runs).
    static func exportMind(profile: String, directory: URL, executable: String = AgentMailService.brigliaPath()) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = ["--profile", profile, "__mind-export", "--to", directory.path]
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: AssistantProfile.environmentKey)
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let last = text.split(separator: "\n").last.map(String.init) ?? ""
        guard p.terminationStatus == 0, last.hasPrefix("/") else {
            throw LifecycleError(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return last
    }

    // MARK: Remove (§5.7)

    struct Hooks {
        var paths: AssistantRegistry.Paths = .live
        var leaseDirectory: (String, String) -> URL = { MemberLeases.extraDirectory($0, generation: $1) }
        var configRoot: (String) -> URL = { AssistantProfile.extraConfigRoot($0) }
        var dataRoot: (String) -> URL = { AssistantProfile.extraDataRoot($0) }
        var barrierActive: () -> Bool = { UpgradeBarrier.current()?.isActive == true }
        var disableUnit: (String) -> Void = { AgentServiceSupport.disableExtraUnitIfPresent($0) }
        var removePreferences: (String) -> Void = { name in
            if let suite = Prefs.suiteName(profile: name) { Prefs.domains.removePersistentDomain(forName: suite) }
        }
        var homeFolder: (String) -> String? = { AssistantProfile.readMetadata($0)?.homeFolder }
        /// The ChatGPT sharing lock (§25.11, §25.14): held from before the
        /// first membership mutation until removal returns.
        var shareLock: () throws -> ProfileFileLock? = { try ChatGPTShare.takeLock() }
        /// Test seam: runs after `removing` was published, before the probe.
        var afterPublish: () -> Void = {}
    }

    /// Returns the user folders that were kept.
    @discardableResult
    static func remove(name: String, confirmedGeneration: String, hooks: Hooks = Hooks()) throws -> [String] {
        let paths = hooks.paths
        try PrivateStorage.ensureDirectory(paths.txDir, mode: 0o700)
        let op = UUID().uuidString.lowercased()
        guard case .acquired(let remover) = ProfileFileLock.take(paths.txLease(op)) else {
            throw LifecycleError("could not create the removal lease")
        }
        MemberEntry.noteOwnTx(op)
        defer {
            remover.release()
            try? FileManager.default.removeItem(at: paths.txLease(op))
            MemberEntry.forgetOwnTx(op)
        }
        let share = try hooks.shareLock()
        defer { share?.release() }
        let home = hooks.homeFolder(name)
        // 1. Publish `removing` (or adopt a dead remover's operation).
        try AssistantRegistry.withLock(paths) { doc in
            guard var d = doc, let i = d.index(name) else { throw LifecycleError("there is no assistant ‘\(name)’") }
            if hooks.barrierActive() { throw LifecycleError("Briglia is updating; try again in a minute") }
            guard d.records[i].generation == confirmedGeneration else {
                throw LifecycleError("‘\(name)’ changed since you confirmed (it was removed and added again); nothing was removed")
            }
            if d.records[i].state == "removing", let other = d.records[i].removingOp,
               ProfileFileLock.probe(paths.txLease(other)) != .dead {
                throw LifecycleError("another removal of ‘\(name)’ is running")
            }
            d.records[i].state = "removing"
            d.records[i].removingOp = op
            doc = d
        }
        hooks.afterPublish()
        // 2. Then look: every lease of this generation, every live writer.
        func restore(_ why: String) throws -> Never {
            try? AssistantRegistry.withLock(paths) { doc in
                guard var d = doc, let i = d.index(name), d.records[i].removingOp == op else { return }
                d.records[i].state = "active"
                d.records[i].removingOp = nil
                doc = d
            }
            throw LifecycleError(why)
        }
        let leaseDir = hooks.leaseDirectory(name, confirmedGeneration)
        let users = MemberLeases.users(leaseDir)
        if let user = users.first {
            let role = user.sidecar?.role ?? "an unknown process"
            let pid = user.sidecar.map { " (pid \($0.pid))" } ?? ""
            try restore("‘\(name)’ is in use by \(role == "assistant" ? "a running assistant" : role)\(pid); stop it first (`briglia profiles stop \(name)`)")
        }
        let doc = try AssistantRegistry.read(paths)
        if let record = doc?.record(name) {
            for (_, active) in record.activeTx where ProfileFileLock.probe(paths.txLease(active.txId)) != .dead {
                try restore("a settings change of ‘\(name)’ is still finishing; try again in a moment")
            }
        }
        // 4. Disable autostart, delete its private state.
        hooks.disableUnit(name)
        hooks.removePreferences(name)
        let fm = FileManager.default
        for root in [hooks.configRoot(name), hooks.dataRoot(name)] where fm.fileExists(atPath: root.path) {
            do { try fm.removeItem(at: root) } catch {
                throw LifecycleError("could not delete \(root.path) (\(error.localizedDescription)); run `briglia profiles remove \(name)` again")
            }
        }
        // 5. Drop the record if this is still our operation, then the lease
        //    directory (a late, rejected starter's held lease keeps it).
        try AssistantRegistry.withLock(paths) { doc in
            guard var d = doc, let i = d.index(name), d.records[i].removingOp == op else { return }
            d.records.remove(at: i)
            doc = d
        }
        MemberLeases.sweep(leaseDir)
        // rmdir, never a recursive removal: a directory that still holds a
        // late starter's lease (or another generation) is kept.
        rmdir(leaseDir.path)
        rmdir(leaseDir.deletingLastPathComponent().path)
        return [home].compactMap { $0 }
    }

    // MARK: Stop

    enum StopResult: Equatable { case notRunning, stopped([Int32]), failed(String) }

    static func stop(name: String, wait: TimeInterval = 30, signalNumber: Int32 = SIGTERM,
                     leaseDirectory: URL? = nil) -> StopResult {
        let dir: URL
        if let leaseDirectory { dir = leaseDirectory } else if name == AssistantProfile.defaultName {
            dir = MemberLeases.defaultDirectory()
        } else {
            guard let record = (try? AssistantRegistry.read(.live))??.record(name) else {
                return .failed("There is no assistant ‘\(name)’ on this computer.")
            }
            dir = MemberLeases.extraDirectory(name, generation: record.generation)
        }
        let assistants = MemberLeases.users(dir, assistantsOnly: true)
        guard !assistants.isEmpty else { return .notRunning }
        var signalled: [Int32] = []
        for entry in assistants {
            guard let side = entry.sidecar, entry.probe == .live else {
                return .failed("‘\(name)’ has a lease that cannot be identified; stop it in its own window")
            }
            guard validated(side) else {
                return .failed("the process recorded for ‘\(name)’ (pid \(side.pid)) is not the one that holds its lease; nothing was signalled")
            }
            if kill(side.pid, signalNumber) == 0 { signalled.append(side.pid) }
        }
        let deadline = Date().addingTimeInterval(wait)
        while Date() < deadline {
            if MemberLeases.users(dir, assistantsOnly: true).isEmpty { return .stopped(signalled) }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return .failed("‘\(name)’ did not stop within \(Int(wait)) s (it may be finishing a reply)")
    }

    /// The recorded pid is the lease holder: same start time and executable.
    static func validated(_ side: MemberLease.Sidecar) -> Bool {
        guard side.pid > 1, let start = ProcessIdentity.startTime(side.pid), start == side.processStartTime else { return false }
        guard let exe = ProcessIdentity.executable(side.pid) else { return false }
        return URL(fileURLWithPath: exe).resolvingSymlinksInPath().path
            == URL(fileURLWithPath: side.executable).resolvingSymlinksInPath().path
    }
}

/// Hidden: export the SELECTED profile's Mind while it is not running
/// (used by `profiles remove`). Prints the archive path as the last line.
struct MindExportOfflineCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__mind-export",
        abstract: "Internal: export this assistant's memory while it is stopped.",
        shouldDisplay: false
    )

    @Option(name: .customLong("to")) var to: String
    @Flag(name: .customLong("lite")) var lite = false

    func run() async throws {
        if SetupAPICore.daemonRunning() {
            print("✖ this assistant is running; stop it first")
            throw ExitCode(1)
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let profileTag = AssistantProfile.isDefault ? "" : "-\(AssistantProfile.selectedName)"
        let destination = URL(fileURLWithPath: to, isDirectory: true)
            .appendingPathComponent("briglia-mind\(profileTag)\(lite ? "-lite" : "")-\(formatter.string(from: Date())).\(MindExportService.fileExtension)")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await MindExportService.shared.exportMind(to: destination, scope: lite ? .lite : .full)
        print(destination.path)
    }
}
