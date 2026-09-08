import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// MARK: - Mind Export Service

/// Handles exporting and importing all user data for portability
actor MindExportService {
    static let shared = MindExportService()
    
    // MARK: - Configuration
    
    /// Version for forward compatibility
    private let exportVersion = "1.1"
    
    /// File extension for mind exports
    static let fileExtension = "mind"
    
    /// Base app folder
    private let appFolder: URL = {
        let folder = StoragePaths.dataRoot
        try? PrivateStorage.ensureDirectory(folder)
        return folder
    }()

    /// User-editable configuration (skills, agents, MCP config): kept in
    /// ~/.config/briglia so it is easy for users to inspect and share.
    /// Root of the subagent-session store. Was StoragePaths.configRoot by
    /// mistake until 2026-08-20 (Codex round 3): SubagentSessionRegistry
    /// persists under DATA root, so exports silently included no sessions
    /// and imports restored them into a directory nothing reads. Old
    /// backups simply lack the folder — restoreDirectory's missing-folder
    /// path already handles that.
    private let homeFolder: URL = {
        let folder = StoragePaths.dataRoot
        try? PrivateStorage.ensureDirectory(folder)
        return folder
    }()
    
    // MARK: - Export

    /// What an export carries (owner, 2026-08-27). `.full` is everything.
    /// `.lite` is the MEMORY only — conversation, archives, reminders +
    /// watcher scripts, calendar, todos, ledger, contacts, subagent
    /// sessions, persona — skipping the bulky payload folders below, which
    /// can dwarf the memory by orders of magnitude (user documents,
    /// original-size images, per-read attachment snapshots, cloned project
    /// repos). Restoring a lite backup follows the normal replacement
    /// semantics: the target's payload folders are CLEARED — the import
    /// warning discloses exactly which areas arrive empty. Pruning snapshots
    /// are memory and included in both scopes; lite is not a size guarantee.
    enum ExportScope: String {
        case full
        case lite

        /// The payload folders a lite export skips. Cached file
        /// DESCRIPTIONS still ride in mind_config, so the restored agent
        /// remembers what the files were — it just can't re-open them.
        static let payloadFolderNames = ["images", "documents", "tool_attachments", "projects"]
    }

    /// Export user data to a ZIP file at the specified destination.
    func exportMind(to destination: URL, scope: ExportScope = .full) async throws {
        let fm = FileManager.default
        
        // Create a temporary directory for assembly
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }
        
        // 1. Copy app-support files.
        for fileName in [
            "conversation.json",
            "context_usage.json",
            "contacts.json",
            "reminders.json",
            "calendar.json",
            "files_ledger.json",
            "documents_last_opened.json",
            "todos.json"
        ] {
            try copyItemIfExists(
                from: appFolder.appendingPathComponent(fileName),
                to: tempDir.appendingPathComponent(fileName)
            )
        }

        // 2. Copy app-support folders. reminder-scripts (with its state/
        // subfolder) rides along since 2026-08-27 (Codex): reminders.json
        // stores only absolute script paths, so a backup without the script
        // bodies and their $WATCHER_STATE restored nothing runnable.
        for folderName in [
            "archive",
            "prune-archives",
            "images",
            "documents",
            "tool_attachments",
            "projects",
            "reminder-scripts"
        ] where scope == .full || !ExportScope.payloadFolderNames.contains(folderName) {
            if folderName == "prune-archives" {
                let source = appFolder.appendingPathComponent(folderName)
                let destination = tempDir.appendingPathComponent(folderName)
                let completed = try PruneArchiveStore.entries(directory: source)
                if !completed.isEmpty {
                    try PrivateStorage.ensureDirectory(destination)
                    for entry in completed {
                        try copyItemIfExists(from: source.appendingPathComponent(entry.reference.basename),
                                             to: destination.appendingPathComponent(entry.reference.basename))
                    }
                    _ = try PruneArchiveStore.entries(directory: destination, validateComplete: true)
                }
                continue
            }
            try copyItemIfExists(
                from: appFolder.appendingPathComponent(folderName, isDirectory: true),
                to: tempDir.appendingPathComponent(folderName, isDirectory: true)
            )
        }

        // 3. Copy home-backed memory stores.
        try copyItemIfExists(
            from: homeFolder.appendingPathComponent("subagent_sessions", isDirectory: true),
            to: tempDir.appendingPathComponent("subagent_sessions", isDirectory: true)
        )

        try ResponsesMindExport.sanitize(tempDir)

        // 4. Create mind_config.json with Keychain and UserDefaults data.
        let config = buildMindConfig()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let configData = try encoder.encode(config)
        try configData.write(to: tempDir.appendingPathComponent("mind_config.json"))
        
        // 5. Create ZIP archive using native macOS zip command.
        // The destination is NOT touched until a complete archive exists
        // (Codex, 2026-08-27): createZipArchive hands the finished zip over
        // atomically, so an existing backup survives every failure mode —
        // zip error, full disk, failed copy. (The old delete-then-copy left
        // the user with nothing, or a torn file, when a later step failed.)
        try await createZipArchive(from: tempDir, to: destination)
        
        print("[MindExportService] Exported mind to: \(destination.path)")
    }
    
    // MARK: - Import

    /// A validated, extracted Mind archive awaiting application. Producing
    /// one is READ-ONLY; the caller decides whether to apply (destructive
    /// replacement) or discard it. Ordering contract (Codex round 3 on the
    /// Ada.app arc, 2026-08-26): the import flow must stage FIRST — a
    /// corrupt or non-Mind archive has to reject here, before any
    /// destructive step (subagent cancellation, pre-import output discard)
    /// runs against the current Mind.
    struct StagedMind {
        let tempDir: URL
        fileprivate let config: MindConfig
        /// Surfaced for the /importmind proposal message, so the user
        /// confirms against the backup's real date rather than a filename.
        var exportDate: Date { config.exportDate }
        var exportVersion: String { config.version }
    }

    /// Phase 1 — extract the archive and validate it is a real Mind
    /// backup. Touches NO current data; when this throws, nothing anywhere
    /// has changed.
    func stageMind(from source: URL) async throws -> StagedMind {
        let fm = FileManager.default

        // Create a temporary directory for extraction. Ownership passes to
        // the returned StagedMind — applyStagedMind/discardStagedMind
        // remove it.
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        do {
            try await extractZipArchive(from: source, to: tempDir)

            // Validate and decode the config BEFORE anything touches current
            // data. Every mind export contains mind_config.json; a
            // random-but-valid zip (e.g. an app bundle) does not. Applying a
            // backup deletes current files even when the backup lacks them,
            // so proceeding without this gate would wipe the user's memory
            // and restore nothing.
            // Fallback to any *_config.json for backward/forward compatibility.
            let preferredConfigSource = tempDir.appendingPathComponent("mind_config.json")
            let configSource: URL?
            if fm.fileExists(atPath: preferredConfigSource.path) {
                configSource = preferredConfigSource
            } else {
                configSource = try? fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
                    .filter { $0.lastPathComponent.hasSuffix("_config.json") }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                    .first
            }
            guard let configSource else {
                throw MindExportError.notAMindBackup
            }
            let config: MindConfig
            do {
                let configData = try Data(contentsOf: configSource)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                config = try decoder.decode(MindConfig.self, from: configData)
            } catch {
                throw MindExportError.notAMindBackup
            }
            // The archive is untrusted input: a symlink (or a socket, FIFO,
            // device) at a harness-owned destination — conversation.json,
            // archive/, subagent_sessions/ … — would redirect the harness's
            // own state. Refused here, before anything current is touched.
            if let offender = try Self.unsafeStagedEntry(in: tempDir, restoredInto: appFolder) {
                throw MindExportError.unsafeArchive(offender)
            }
            _ = try PruneArchiveStore.entries(directory: tempDir.appendingPathComponent("prune-archives"), validateComplete: true)
            return StagedMind(tempDir: tempDir, config: config)
        } catch {
            try? fm.removeItem(at: tempDir)
            throw error
        }
    }

    /// Abandon a staged Mind without applying it (a pre-apply step aborted
    /// after successful validation, or the /importmind proposal step, which
    /// stages purely to validate early).
    func discardStagedMind(_ staged: StagedMind) {
        try? FileManager.default.removeItem(at: staged.tempDir)
    }

    /// Phase 2 — apply a validated staged Mind: the destructive replacement
    /// of current data. Call only once the import is committed (producers
    /// quiescent, pre-import outputs discarded).
    func applyStagedMind(_ staged: StagedMind) throws {
        let tempDir = staged.tempDir
        let config = staged.config
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 2. Restore app-support files. Missing files in older backups clear
        // the current counterpart so import behaves like a real replacement.
        for fileName in [
            "conversation.json",
            "context_usage.json",
            "contacts.json",
            "reminders.json",
            "calendar.json",
            "files_ledger.json",
            "documents_last_opened.json",
            "todos.json"
        ] {
            try restoreFile(named: fileName, from: tempDir, to: appFolder)
        }

        // 3. Restore app-support folders. Older backups without
        // reminder-scripts clear the current one — correct replacement
        // semantics (their reminders.json had no runnable watchers anyway).
        for folderName in [
            "archive",
            "prune-archives",
            "images",
            "documents",
            "tool_attachments",
            "projects",
            "reminder-scripts"
        ] {
            try restoreDirectory(named: folderName, from: tempDir, to: appFolder)
        }

        // 4. Restore home-backed memory stores.
        try restoreDirectory(named: "subagent_sessions", from: tempDir, to: homeFolder)

        // 5. Apply the config decoded during validation (persona + file descriptions).
        try restoreMindConfig(config)

        // 6. Everything restored in scope is owner-only, checked.
        try validateRestoredPermissions()
        try PruneArchiveStore.retainLatest(directory: appFolder.appendingPathComponent("prune-archives"))

        print("[MindExportService] Applied staged mind from: \(tempDir.path)")
    }

    // MARK: - Staged-tree validation and policy-aware restore

    /// Payload the restore touches, as it appears in the archive root.
    static let restoredFileNames = [
        "conversation.json", "context_usage.json", "contacts.json", "reminders.json",
        "calendar.json", "files_ledger.json", "documents_last_opened.json", "todos.json",
    ]
    static let restoredFolderNames = [
        "archive", "prune-archives", "images", "documents", "tool_attachments", "projects", "reminder-scripts",
        "subagent_sessions",
    ]

    /// First entry of the staged payload that must not be restored: a
    /// top-level file entry that is not a regular file, a top-level folder
    /// entry that is not a real directory (a symlink, a dangling link, a
    /// file where a directory belongs, or the reverse — applying it would
    /// replace a valid current object with one the harness cannot use), a
    /// symlink deeper in the tree whose destination classifies as
    /// harness-owned state, or any object that is neither a regular file,
    /// a directory nor a symlink. Symlinks inside user content (documents/,
    /// projects/, …) are allowed and recreated as links. Presence is
    /// checked with `lstat`, so a dangling link is seen, not treated as
    /// absent.
    static func unsafeStagedEntry(in tempDir: URL, restoredInto dataRoot: URL) throws -> String? {
        let fm = FileManager.default
        func kind(_ path: String) -> mode_t? {
            var st = stat()
            guard lstat(path, &st) == 0 else { return nil }
            return st.st_mode & S_IFMT
        }
        for name in restoredFileNames {
            guard let k = kind(tempDir.appendingPathComponent(name).path) else { continue }
            if k != S_IFREG { return "\(name) must be a regular file" }
        }
        for name in restoredFolderNames {
            guard let k = kind(tempDir.appendingPathComponent(name).path) else { continue }
            if k != S_IFDIR { return "\(name) must be a directory" }
        }
        func visit(_ source: URL, _ destination: URL, depth: Int) throws -> String? {
            guard depth < 64 else { return "\(source.path): tree too deep" }
            var st = stat()
            guard lstat(source.path, &st) == 0 else { return nil }
            let fmt = st.st_mode & S_IFMT
            switch fmt {
            case S_IFREG:
                return nil
            case S_IFLNK:
                if PrivateStorage.classify(destination.path, configRoot: StoragePaths.configRoot, dataRoot: dataRoot) == .harnessState {
                    return "symlink at harness-owned path \(destination.lastPathComponent)"
                }
                return nil
            case S_IFDIR:
                for name in (try fm.contentsOfDirectory(atPath: source.path)).sorted() {
                    if let bad = try visit(source.appendingPathComponent(name),
                                           destination.appendingPathComponent(name), depth: depth + 1) {
                        return bad
                    }
                }
                return nil
            default:
                return "\(destination.lastPathComponent) is not a regular file, directory or symlink"
            }
        }
        for name in restoredFolderNames {
            let source = tempDir.appendingPathComponent(name)
            guard kind(source.path) != nil else { continue }
            if let bad = try visit(source, dataRoot.appendingPathComponent(name), depth: 0) { return bad }
        }
        return nil
    }

    // MARK: - File Copy Helpers

    private func copyItemIfExists(from source: URL, to destination: URL) throws {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private func restoreFile(named fileName: String, from tempDir: URL, to destinationDir: URL) throws {
        let source = tempDir.appendingPathComponent(fileName)
        let destination = destinationDir.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: destination)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try PrivateStorage.ensureDirectory(destinationDir)
        // Policy-aware: an older backup carries 0644 files; they land 0600.
        try PrivateStorage.copyTree(from: source, to: destination)
    }

    private func restoreDirectory(named folderName: String, from tempDir: URL, to destinationDir: URL) throws {
        let source = tempDir.appendingPathComponent(folderName, isDirectory: true)
        let destination = destinationDir.appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.removeItem(at: destination)
        try PrivateStorage.ensureDirectory(destinationDir)
        if FileManager.default.fileExists(atPath: source.path) {
            if folderName == "projects" {
                // The user's work product is outside the policy: restored
                // as archived, modes included.
                try FileManager.default.copyItem(at: source, to: destination)
            } else {
                try PrivateStorage.copyTree(from: source, to: destination)
            }
        } else {
            try PrivateStorage.ensureDirectoryScoped(destination)
        }
    }

    /// Post-restore check: nothing restored in scope may carry group/other
    /// bits. A miss is repaired by the sweep and re-checked; a second miss
    /// is an error (the data is in place, but the promise is not met).
    private func validateRestoredPermissions() throws {
        func wide() -> [String] {
            var out: [String] = []
            for name in Self.restoredFileNames + Self.restoredFolderNames where name != "projects" {
                out += PrivateStorage.wideEntries(under: appFolder.appendingPathComponent(name))
            }
            return out
        }
        if wide().isEmpty { return }
        PrivateStorage.sweep()
        let remaining = wide()
        if !remaining.isEmpty {
            throw MindExportError.permissionsNotApplied(remaining.prefix(5).joined(separator: ", "))
        }
    }
    
    // MARK: - ZIP Operations

    /// Resolve `zip`/`unzip` for the current platform. Hardcoded
    /// /usr/bin worked while this service was dormant macOS-only code;
    /// as a live cross-platform feature the binaries may be absent
    /// (minimal Linux, Ubuntu Touch) — fail with an actionable message
    /// instead of a bare NSCocoaError. The .mind format stays zip on
    /// purpose: backups must round-trip with Ada.app.
    private static func findArchiveTool(_ name: String) throws -> String {
        var candidates = ["/usr/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/\(name)" }
        }
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        throw MindExportError.toolMissing(name)
    }

    /// Test seam: force createZipArchive to fail before writing anything —
    /// coverage for "a failed export must not destroy the existing backup".
    private var injectZipFailure = false
    func _testInjectZipFailure(_ enabled: Bool) { injectZipFailure = enabled }

    private func createZipArchive(from sourceDir: URL, to destination: URL) async throws {
        let fm = FileManager.default

        if injectZipFailure {
            throw MindExportError.zipFailed("injected zip failure (test seam)")
        }

        // Create zip in temp directory first — the destination must not be
        // touched until a complete archive exists.
        let tempZip = fm.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).zip")
        defer { try? fm.removeItem(at: tempZip) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: try Self.findArchiveTool("zip"))
        process.currentDirectoryURL = sourceDir
        process.arguments = ["-r", "-q", tempZip.path, "."]
        
        let pipe = Pipe()
        process.standardError = pipe
        
        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus != 0 {
            let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw MindExportError.zipFailed(errorMessage)
        }
        
        // Atomic hand-off (Codex, 2026-08-27): copy the finished zip to a
        // hidden SIBLING of the destination (same directory → same volume),
        // then rename(2) it into place — atomic replacement on both Darwin
        // and Linux, whether or not the destination already exists. The
        // previous backup survives until a complete replacement is in
        // place, and no partial file can ever sit at the destination path.
        let sibling = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).tmp-\(UUID().uuidString.prefix(8))")
        defer { try? fm.removeItem(at: sibling) }
        try fm.copyItem(at: tempZip, to: sibling)
        let renamed = sibling.path.withCString { source in
            destination.path.withCString { dest in rename(source, dest) }
        }
        if renamed != 0 {
            throw MindExportError.zipFailed("could not move the finished archive into place: \(String(cString: strerror(errno)))")
        }
    }
    
    private func extractZipArchive(from source: URL, to destinationDir: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try Self.findArchiveTool("unzip"))
        process.arguments = ["-q", source.path, "-d", destinationDir.path]
        
        let pipe = Pipe()
        process.standardError = pipe
        
        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus != 0 {
            let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw MindExportError.unzipFailed(errorMessage)
        }
    }
    
    // MARK: - Mind Config
    
    fileprivate struct MindConfig: Codable {
        let version: String
        let exportDate: Date
        let persona: PersonaConfig
        let fileDescriptions: [String: String]
    }
    
    fileprivate struct PersonaConfig: Codable {
        let assistantName: String?
        let userName: String?
        let userContext: String?
        let structuredUserContext: String?
    }
    
    private func buildMindConfig() -> MindConfig {
        // Load persona settings from Keychain
        let persona = PersonaConfig(
            assistantName: KeychainHelper.load(key: KeychainHelper.assistantNameKey),
            userName: KeychainHelper.load(key: KeychainHelper.userNameKey),
            userContext: KeychainHelper.load(key: KeychainHelper.userContextKey),
            structuredUserContext: KeychainHelper.load(key: KeychainHelper.structuredUserContextKey)
        )

        // Load file descriptions
        var fileDescriptions: [String: String] = [:]
        if let data = FileDescriptionsStore.loadData(),
           let descriptions = try? JSONDecoder().decode([String: String].self, from: data) {
            fileDescriptions = descriptions
        }

        return MindConfig(
            version: exportVersion,
            exportDate: Date(),
            persona: persona,
            fileDescriptions: fileDescriptions
        )
    }

    private func restoreMindConfig(_ config: MindConfig) throws {
        // Full replacement: the backup's persona and file descriptions
        // REPLACE the destination's, absences included — a nil persona field
        // deletes the old value and an empty description map still overwrites,
        // so a fresh/lite backup can't inherit the previous Mind's cached
        // file memories or name.
        try KeychainHelper.saveBatch([
            KeychainHelper.assistantNameKey: config.persona.assistantName,
            KeychainHelper.userNameKey: config.persona.userName,
            KeychainHelper.userContextKey: config.persona.userContext,
            KeychainHelper.structuredUserContextKey: config.persona.structuredUserContext,
        ])

        try FileDescriptionsStore.storeData(try JSONEncoder().encode(config.fileDescriptions))
    }
}

// MARK: - Errors

enum MindExportError: LocalizedError {
    case zipFailed(String)
    case unzipFailed(String)
    case notAMindBackup
    case toolMissing(String)
    case unsafeArchive(String)
    case permissionsNotApplied(String)

    var errorDescription: String? {
        switch self {
        case .zipFailed(let message):
            return "Failed to create archive: \(message)"
        case .unzipFailed(let message):
            return "Failed to extract archive: \(message)"
        case .notAMindBackup:
            return "The selected file is not an Briglia memory backup (mind_config.json missing). No data was changed."
        case .unsafeArchive(let what):
            return "The backup contains an entry that must not be restored (\(what)). No data was changed."
        case .permissionsNotApplied(let what):
            return "The backup was restored but some entries could not be made owner-only: \(what)"
        case .toolMissing(let name):
            return "`\(name)` is not installed on this machine — install it (Linux: `sudo apt install zip unzip`) and retry. No data was changed."
        }
    }
}
