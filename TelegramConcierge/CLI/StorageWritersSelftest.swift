import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Writer-level storage checks, called from `StorageSelftest` section 6:
/// state files written by the real services come out owner-only, and
/// executable artefacts (reminder scripts, wrappers) keep working after the
/// sweep and after rewrites. Kept in its own file so the writer-routing work
/// can grow it without touching the core selftest.
///
/// Runs against the throwaway XDG roots the core selftest already pointed
/// `StoragePaths` at, with umask 022 — so every `0600`/`0700` below is the
/// writer's doing, not the environment's.
enum StorageWritersSelftest {
    private static func mode(_ path: String) -> Int {
        var st = stat()
        guard lstat(path, &st) == 0 else { return -1 }
        return Int(st.st_mode & 0o7777)
    }

    private static func octal(_ m: Int) -> String { m < 0 ? "absent" : String(m, radix: 8) }

    private static func contents(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? "<unreadable>"
    }

    /// Plants a file with an exact mode, creating parents under the umask.
    private static func plant(_ path: String, _ text: String, _ m: Int) throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: false, encoding: .utf8)
        _ = chmod(path, mode_t(m))
    }

    /// Runs an executable directly (no shell), returning exit status + stdout.
    private static func exec(_ path: String, env: [String: String] = [:]) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        var environment = ProcessInfo.processInfo.environment
        for (k, v) in env { environment[k] = v }
        p.environment = environment
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "\(error)") }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (p.terminationStatus, out)
    }

    static func run(tempRoot: URL, check: (String, Bool, String) -> Void) async {
        let fm = FileManager.default
        let dataRoot = StoragePaths.dataRoot
        let configRoot = StoragePaths.configRoot
        StoragePaths.ensureRoots()

        // MARK: (a) reminder script — 0700 script, 0600 state, executes after the sweep
        let scriptSource = """
        #!/bin/sh
        if [ ! -e "$WATCHER_STATE" ]; then : > "$WATCHER_STATE"; fi
        echo ran >> "$WATCHER_STATE"
        exit 0

        """
        var reminderId: UUID? = nil
        do {
            let (reminder, _) = try await ReminderService.shared.createScriptedReminder(
                triggerDate: Date().addingTimeInterval(86_400),
                prompt: "storage selftest watcher",
                recurrence: .daily,
                scriptSource: scriptSource,
                deleteAfterFire: false)
            reminderId = reminder.id
            check("6.1 scripted reminder registered (seed + silent run passed)", true, "")
        } catch {
            check("6.1 scripted reminder registered (seed + silent run passed)", false, "\(error)")
        }
        let scriptsDir = dataRoot.appendingPathComponent("reminder-scripts")
        let stateDir = scriptsDir.appendingPathComponent("state")
        if let id = reminderId {
            let script = scriptsDir.appendingPathComponent("\(id.uuidString).sh").path
            let state = stateDir.appendingPathComponent("\(id.uuidString).txt").path
            check("6.2 reminder script written 0700", mode(script) == 0o700, octal(mode(script)))
            check("6.3 reminder-scripts/ and state/ are 0700",
                  mode(scriptsDir.path) == 0o700 && mode(stateDir.path) == 0o700,
                  "\(octal(mode(scriptsDir.path))) \(octal(mode(stateDir.path)))")
            // The watcher command runs under `umask 077`, so the state file
            // the script creates is owner-only from the start (no wait for
            // the next startup sweep).
            check("6.4 state file created by the script is 0600 (watcher umask 077)",
                  mode(state) == 0o600, octal(mode(state)))
            let remindersFile = dataRoot.appendingPathComponent("reminders.json").path
            let noticesFile = dataRoot.appendingPathComponent("reminder-notices.json").path
            check("6.5 reminders.json written 0600", mode(remindersFile) == 0o600, octal(mode(remindersFile)))
            check("6.6 reminder-notices.json written 0600", mode(noticesFile) == 0o600, octal(mode(noticesFile)))

            let sweep = PrivateStorage.sweep()
            check("6.7 sweep finds nothing to tighten for the watcher's files",
                  mode(state) == 0o600 && sweep.errors.isEmpty, "\(octal(mode(state))) errors=\(sweep.errors)")
            check("6.8 script still 0700 after the sweep", mode(script) == 0o700, octal(mode(script)))
            let before = contents(state)
            let direct = exec(script, env: ["WATCHER_STATE": state])
            check("6.9 script executes DIRECTLY after the sweep (exec bit kept)",
                  direct.status == 0 && contents(state) == before + "ran\n",
                  "status=\(direct.status) state=\(contents(state).debugDescription)")
            check("6.10 state file rewritten by the script keeps 0600", mode(state) == 0o600, octal(mode(state)))
            let shellRun = Process()
            shellRun.executableURL = URL(fileURLWithPath: "/bin/sh")
            shellRun.arguments = ["-c", "WATCHER_STATE=\"\(state)\" \"\(script)\""]
            shellRun.standardOutput = FileHandle.nullDevice
            shellRun.standardError = FileHandle.nullDevice
            try? shellRun.run()
            shellRun.waitUntilExit()
            check("6.11 script executes via /bin/sh -c after the sweep", shellRun.terminationStatus == 0,
                  "status=\(shellRun.terminationStatus)")
        }

        // MARK: (b) conversation.json — real save path, planted 0644 → 0600, content replaced
        let conversationFile = dataRoot.appendingPathComponent("conversation.json").path
        let imagesDir = dataRoot.appendingPathComponent("images").path
        let toolAttachmentsDir = dataRoot.appendingPathComponent("tool_attachments").path
        do {
            // A DECODABLE history with different bytes: an undecodable file
            // is preserved for repair and never overwritten (mid-turn wake
            // storage rule), so it cannot exercise the rewrite path.
            try plant(conversationFile, "[ ]", 0o644)
            _ = chmod(imagesDir, 0o755)
            let result: (mode: Int, text: String, images: Int, attachments: Int) = await MainActor.run {
                let manager = ConversationManager()
                manager.clearConversation()
                return (mode(conversationFile), contents(conversationFile), mode(imagesDir), mode(toolAttachmentsDir))
            }
            check("6.12 ConversationManager save rewrites a planted 0644 conversation.json as 0600",
                  result.mode == 0o600, octal(result.mode))
            check("6.13 …and the content is the new (empty) history, not the planted bytes",
                  result.text == "[]", result.text.debugDescription)
            check("6.14 images/ and tool_attachments/ recreated 0700 by the real code path",
                  result.images == 0o700 && result.attachments == 0o700,
                  "\(octal(result.images)) \(octal(result.attachments))")
        } catch {
            check("6.12 ConversationManager save rewrites a planted 0644 conversation.json as 0600", false, "\(error)")
        }

        // MARK: (c) trigger spool + fire outbox — 0600 records inside 0700 directories
        let spoolDir = TriggerSpool.directoryURL
        // Plant the spool dir wide first: the writer must tighten it.
        try? fm.createDirectory(at: spoolDir, withIntermediateDirectories: true)
        _ = chmod(spoolDir.path, 0o755)
        let watcherId = UUID()
        do {
            let result = try TriggerSpool.write(watcherId: watcherId, payload: "storage selftest event")
            if case .spooled(let url) = result {
                check("6.15 trigger-events record written 0600", mode(url.path) == 0o600, octal(mode(url.path)))
                try? fm.removeItem(at: url)
            } else {
                check("6.15 trigger-events record written 0600", false, "not spooled: \(result)")
            }
            check("6.16 trigger-events/ tightened 0755 → 0700 by the writer",
                  mode(spoolDir.path) == 0o700, octal(mode(spoolDir.path)))
            let lock = spoolDir.appendingPathComponent(".spool.lock").path
            check("6.17 spool lock file is 0600", mode(lock) == 0o600, octal(mode(lock)))
        } catch {
            check("6.15 trigger-events record written 0600", false, "\(error)")
        }
        let record = FireRecord(watcherId: watcherId, source: .external, content: "storage selftest fire")
        let persisted = FireOutbox.persist(record)
        let recordPath = FireOutbox.directoryURL.appendingPathComponent("\(record.id.uuidString).json").path
        check("6.18 fire-outbox record written 0600", persisted && mode(recordPath) == 0o600,
              "persisted=\(persisted) \(octal(mode(recordPath)))")
        check("6.19 fire-outbox/ is 0700", mode(FireOutbox.directoryURL.path) == 0o700,
              octal(mode(FireOutbox.directoryURL.path)))
        FireOutbox.remove(record.id)

        // MARK: (d) projects/ is not tightened by the scope-aware directory helper
        // (the routine MindExportService.restoreDirectory uses for a restored
        // empty folder — `projects/` is the user's work product).
        let projectsDemo = dataRoot.appendingPathComponent("projects/demo")
        do {
            try PrivateStorage.ensureDirectoryScoped(projectsDemo)
            check("6.20 projects/<dir> created under the umask (0755), NOT 0700",
                  mode(projectsDemo.path) == 0o755, octal(mode(projectsDemo.path)))
            check("6.21 projects/ itself left under the umask (0755)",
                  mode(dataRoot.appendingPathComponent("projects").path) == 0o755,
                  octal(mode(dataRoot.appendingPathComponent("projects").path)))
            let external = tempRoot.appendingPathComponent("external-scoped/x")
            try PrivateStorage.ensureDirectoryScoped(external)
            check("6.22 an outside-the-roots dir is created under the umask (0755)",
                  mode(external.path) == 0o755, octal(mode(external.path)))
            let inScope = dataRoot.appendingPathComponent("images/nested")
            try PrivateStorage.ensureDirectoryScoped(inScope)
            check("6.23 an in-scope dir goes through the private policy (0700)",
                  mode(inScope.path) == 0o700, octal(mode(inScope.path)))
        } catch {
            check("6.20 projects/<dir> created under the umask (0755), NOT 0700", false, "\(error)")
        }

        // MARK: (e) other routed state writers, through their real APIs
        let ledgerFile = dataRoot.appendingPathComponent("files_ledger.json").path
        await FilesLedger.shared.record(path: tempRoot.appendingPathComponent("probe.txt").path, origin: .generated)
        check("6.24 files_ledger.json written 0600 (no .tmp left behind)",
              mode(ledgerFile) == 0o600 && !fm.fileExists(atPath: ledgerFile + ".tmp"), octal(mode(ledgerFile)))

        let todosFile = dataRoot.appendingPathComponent("todos.json").path
        do {
            try plant(todosFile, "[]", 0o644)
            _ = try await TodoStore.shared.replace(with: [
                Todo(content: "storage selftest", activeForm: "Checking storage", status: "pending"),
            ])
            check("6.25 todos.json rewritten 0644 → 0600 with the new content",
                  mode(todosFile) == 0o600 && contents(todosFile).contains("storage selftest") && !fm.fileExists(atPath: todosFile + ".tmp"),
                  octal(mode(todosFile)))
        } catch {
            check("6.25 todos.json rewritten 0644 → 0600 with the new content", false, "\(error)")
        }

        let calendarFile = dataRoot.appendingPathComponent("calendar.json").path
        do {
            _ = try await CalendarService.shared.addEvent(title: "storage selftest", datetime: Date().addingTimeInterval(3600), notes: nil)
            check("6.26 calendar.json written 0600", mode(calendarFile) == 0o600, octal(mode(calendarFile)))
        } catch {
            check("6.26 calendar.json written 0600", false, "\(error)")
        }

        // A user-authored file (agents/) rewritten by the harness keeps its
        // owner bits and loses group/other: 0755 → 0700, never 0600-flattened.
        let agentsDir = configRoot.appendingPathComponent("agents")
        let agentFile = agentsDir.appendingPathComponent("storage-probe.md").path
        do {
            try plant(agentFile, "planted", 0o755)
            try SubagentSerializer.save(
                name: "storage-probe", description: "storage selftest agent", systemPrompt: "Say ok.",
                nativeTools: nil, mcpToolPatterns: nil, model: "inherit", maxTurns: 3)
            check("6.27 agents/<name>.md rewrite keeps owner bits, strips group/other (0755 → 0700)",
                  mode(agentFile) == 0o700 && contents(agentFile).contains("storage selftest agent"), octal(mode(agentFile)))
            try fm.removeItem(atPath: agentFile)
            try SubagentSerializer.save(
                name: "storage-probe", description: "storage selftest agent", systemPrompt: "Say ok.",
                nativeTools: nil, mcpToolPatterns: nil, model: "inherit", maxTurns: 3)
            check("6.28 a fresh agents/<name>.md is 0600 in a 0700 agents/",
                  mode(agentFile) == 0o600 && mode(agentsDir.path) == 0o700,
                  "\(octal(mode(agentFile))) \(octal(mode(agentsDir.path)))")
        } catch {
            check("6.27 agents/<name>.md rewrite keeps owner bits, strips group/other (0755 → 0700)", false, "\(error)")
        }

        // Harness-owned state refuses a planted symlink even through the
        // real writer: the trust store's `store` goes through the helper.
        let trustFile = dataRoot.appendingPathComponent("release_trust.json")
        let decoy = tempRoot.appendingPathComponent("decoy-trust.json")
        do {
            try plant(decoy.path, "{}", 0o644)
            try? fm.removeItem(at: trustFile)
            try fm.createSymbolicLink(at: trustFile, withDestinationURL: decoy)
            var refused = false
            do { _ = try ReleaseTrustStore.store(1, domain: "storage-selftest") } catch { refused = true }
            check("6.29 trust-store write through a planted symlink at release_trust.json is refused",
                  refused && contents(decoy.path) == "{}", "refused=\(refused) decoy=\(contents(decoy.path))")
            try? fm.removeItem(at: trustFile)
            _ = try ReleaseTrustStore.store(1, domain: "storage-selftest")
            check("6.30 release_trust.json written 0600, sidecar lock 0600",
                  mode(trustFile.path) == 0o600 && mode(trustFile.path + ".lock") == 0o600,
                  "\(octal(mode(trustFile.path))) \(octal(mode(trustFile.path + ".lock")))")
        } catch {
            check("6.29 trust-store write through a planted symlink at release_trust.json is refused", false, "\(error)")
        }

        // Nothing wide may remain in the swept scope after all of the above
        // (projects/ is excluded and was deliberately left 0755).
        let report = PrivateStorage.sweep(apply: false)
        check("6.31 doctor view: zero wide entries in the swept scope after the writers ran",
              report.tightened == 0, "wide=\(report.tightened) samples=\(report.samples)")
    }
}
