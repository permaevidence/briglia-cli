import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Hidden deterministic test of the /exportmind–/importmind arc.
/// Pins (a) the pre-import disclosure text, (b) the staged read-only
/// validation gate — a corrupt or non-Mind archive rejects with ALL current
/// work intact (no subagent cancelled, no queued output discarded), (c) the
/// quiescence barrier over all three producer classes (registry subagents,
/// watcher checks, detached triage runs), (d) the wipe's 0c-bis triage
/// abort (Codex, 2026-08-27 — the CLI shared Ada.app's gap), (e) the
/// point-of-no-return discard of pre-import outputs, and (f) a full
/// export → mutate → apply round trip in an isolated root.
/// Fully isolated: XDG roots and TMPDIR are pointed at a temp directory
/// BEFORE anything touches KeychainHelper / StoragePaths (their locations
/// freeze at first access — same ordering contract as the other selftests).
struct MindSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__mind-selftest",
        abstract: "Internal: verify Mind export/import staging, quiescence, discard, and disclosures.",
        shouldDisplay: false
    )

    func run() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ada-mind-selftest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        setenv("XDG_CONFIG_HOME", tempRoot.path, 1)
        setenv("XDG_DATA_HOME", tempRoot.path, 1)
        setenv("TMPDIR", tempRoot.path + "/", 1)
        // UserDefaults ignores the XDG roots, and a watchdog exit(3) or
        // kill bypasses defer-based restore — so the description store is
        // redirected to a file that dies with the temp directory instead
        // of ever touching the machine's real preferences. This covers
        // EVERY store path: export/import config, the live service, and
        // the wipe's clearAll.
        FileDescriptionsStore._testStoreURL =
            tempRoot.appendingPathComponent("test-file-descriptions.json")

        let watchdog = Task.detached {
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            if !Task.isCancelled {
                print("WATCHDOG: mind selftest exceeded 120s — hung; aborting")
                Foundation.exit(3)
            }
        }
        defer { watchdog.cancel() }

        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "✔" : "✖") \(label)\(ok || detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }

        // zip/unzip availability mirrors MindExportService's own PATH scan;
        // sections needing real archives skip (loudly) where absent so the
        // suite stays honest on minimal containers without failing forever.
        func archiveTool(_ name: String) -> String? {
            var candidates = ["/usr/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
            if let path = ProcessInfo.processInfo.environment["PATH"] {
                candidates += path.split(separator: ":").map { "\($0)/\(name)" }
            }
            return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        }

        // 1. Pre-import disclosure: replacement scope, the no-automatic-
        // backup fact, and the kept set must all appear BEFORE the
        // confirmation token (the /deleteuserdata disclosure contract).
        do {
            let warning = ConversationManager.importMindWarningText(
                path: "/tmp/backup.mind", exportDate: Date())
            for needle in ["REPLACES", "/tmp/backup.mind", "conversation history",
                           "archives", "reminders and watchers", "subagent session histories",
                           "Kept: API keys", "NOT saved automatically",
                           "shell programs", "arrive PAUSED", "/resumewatcher",
                           "/importmind confirm", "/importmind cancel"] {
                check("import warning discloses: \(needle)", warning.contains(needle))
            }
            if let tokenRange = warning.range(of: "/importmind confirm"),
               let replacedRange = warning.range(of: "Replaced:") {
                check("disclosure precedes the confirmation token",
                      replacedRange.lowerBound < tokenRange.lowerBound)
            } else {
                check("disclosure precedes the confirmation token", false)
            }

            // Lite/absent-payload disclosure: when the backup lacks payload
            // folders the warning must name them and say those areas end up
            // empty — BEFORE the confirmation token.
            let liteWarning = ConversationManager.importMindWarningText(
                path: "/tmp/backup.mind", exportDate: Date(),
                absentPayloadFolders: ["documents", "tool_attachments"])
            check("lite warning names the missing payload areas",
                  liteWarning.contains("documents, attachment snapshots")
                      && liteWarning.contains("EMPTY on this machine"))
            if let noteRange = liteWarning.range(of: "EMPTY on this machine"),
               let tokenRange = liteWarning.range(of: "/importmind confirm") {
                check("lite disclosure precedes the confirmation token",
                      noteRange.lowerBound < tokenRange.lowerBound)
            } else {
                check("lite disclosure precedes the confirmation token", false)
            }
            check("full backup warning omits the empty-areas note",
                  !warning.contains("EMPTY on this machine"))
        }

        // 2. Staging validation, no manager involved.
        if let zip = archiveTool("zip"), archiveTool("unzip") != nil {
            let workDir = tempRoot.appendingPathComponent("stage-check", isDirectory: true)
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

            // 2a. A VALID zip that is NOT a Mind backup (no mind_config.json)
            // must throw notAMindBackup — the validation gate, not a mere
            // unzip failure.
            let payloadDir = workDir.appendingPathComponent("payload", isDirectory: true)
            try FileManager.default.createDirectory(at: payloadDir, withIntermediateDirectories: true)
            try Data("not a mind".utf8).write(to: payloadDir.appendingPathComponent("random.txt"))
            let bogus = workDir.appendingPathComponent("bogus.mind")
            let zipProc = Process()
            zipProc.executableURL = URL(fileURLWithPath: zip)
            zipProc.currentDirectoryURL = payloadDir
            zipProc.arguments = ["-r", "-q", bogus.path, "."]
            try zipProc.run()
            zipProc.waitUntilExit()
            check("stage setup: non-Mind zip created", zipProc.terminationStatus == 0)

            var threwNotAMind = false
            do {
                _ = try await MindExportService.shared.stageMind(from: bogus)
            } catch let error as MindExportError {
                if case .notAMindBackup = error { threwNotAMind = true }
            } catch {}
            check("staging a non-Mind zip throws notAMindBackup", threwNotAMind)

            // 2b. A non-archive file must throw an unzip failure, again
            // read-only.
            let garbage = workDir.appendingPathComponent("garbage.mind")
            try Data("definitely not a zip".utf8).write(to: garbage)
            var threwUnzip = false
            do {
                _ = try await MindExportService.shared.stageMind(from: garbage)
            } catch let error as MindExportError {
                if case .unzipFailed = error { threwUnzip = true }
            } catch {}
            check("staging a corrupt file throws unzipFailed", threwUnzip)
        } else {
            print("⚠ SKIP: zip/unzip not installed — staging-validation checks skipped")
        }

        // 2c. Archive fingerprint: deterministic, size-accurate, and
        // sensitive to any content change — the pin that ties /importmind
        // confirm to the file the user actually inspected.
        do {
            let file = tempRoot.appendingPathComponent("fingerprint.bin")
            try Data("fingerprint-content".utf8).write(to: file)
            let first = ConversationManager.mindArchiveFingerprint(path: file.path)
            let second = ConversationManager.mindArchiveFingerprint(path: file.path)
            check("fingerprint is deterministic",
                  first != nil && first?.sha256 == second?.sha256 && first?.bytes == second?.bytes)
            check("fingerprint reports the exact byte count",
                  first?.bytes == Int64("fingerprint-content".utf8.count))
            try Data("fingerprint-CONTENT".utf8).write(to: file)
            let changed = ConversationManager.mindArchiveFingerprint(path: file.path)
            check("fingerprint changes when the file changes",
                  changed != nil && changed?.sha256 != first?.sha256)
            check("fingerprint of a missing file is nil",
                  ConversationManager.mindArchiveFingerprint(path: file.path + ".absent") == nil)
        }

        // 3. Full export → mutate → apply round trip inside the isolated
        // root: what /exportmind writes is exactly what /importmind
        // restores, including a file the mutated state had deleted and a
        // watcher script + its state (Codex, 2026-08-27: reminders.json
        // alone restored no runnable watcher).
        if archiveTool("zip") != nil, archiveTool("unzip") != nil {
            let dataRoot = StoragePaths.dataRoot
            let conversationFile = dataRoot.appendingPathComponent("conversation.json")
            let documentsDir = dataRoot.appendingPathComponent("documents", isDirectory: true)
            let scriptsDir = dataRoot.appendingPathComponent("reminder-scripts", isDirectory: true)
            let stateDir = scriptsDir.appendingPathComponent("state", isDirectory: true)
            try FileManager.default.createDirectory(at: documentsDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
            let originalConversation = #"{"marker":"round-trip-original"}"#
            try originalConversation.write(to: conversationFile, atomically: true, encoding: .utf8)
            try "important doc".write(
                to: documentsDir.appendingPathComponent("doc.txt"), atomically: true, encoding: .utf8)
            let watcherId = UUID()
            let scriptFile = scriptsDir.appendingPathComponent("\(watcherId.uuidString).sh")
            try "echo watcher-check".write(to: scriptFile, atomically: true, encoding: .utf8)
            try "seen-state".write(
                to: stateDir.appendingPathComponent(watcherId.uuidString), atomically: true, encoding: .utf8)

            let backup = tempRoot.appendingPathComponent("roundtrip.mind")
            try await MindExportService.shared.exportMind(to: backup)
            check("export produced the backup file",
                  FileManager.default.fileExists(atPath: backup.path))

            // Mutate current state: rewrite the conversation, delete the
            // doc, delete the watcher script and its state.
            try #"{"marker":"mutated"}"#.write(to: conversationFile, atomically: true, encoding: .utf8)
            try FileManager.default.removeItem(at: documentsDir.appendingPathComponent("doc.txt"))
            try FileManager.default.removeItem(at: scriptFile)
            try FileManager.default.removeItem(at: stateDir.appendingPathComponent(watcherId.uuidString))

            let staged = try await MindExportService.shared.stageMind(from: backup)
            check("staged backup exposes a recent export date",
                  abs(staged.exportDate.timeIntervalSinceNow) < 300,
                  "\(staged.exportDate)")
            try await MindExportService.shared.applyStagedMind(staged)

            let restored = (try? String(contentsOf: conversationFile, encoding: .utf8)) ?? ""
            check("apply restored the original conversation",
                  restored == originalConversation, String(restored.prefix(80)))
            check("apply restored the deleted document",
                  FileManager.default.fileExists(
                      atPath: documentsDir.appendingPathComponent("doc.txt").path))
            check("apply restored the watcher script",
                  (try? String(contentsOf: scriptFile, encoding: .utf8)) == "echo watcher-check")
            check("apply restored the watcher's seen-state",
                  (try? String(contentsOf: stateDir.appendingPathComponent(watcherId.uuidString),
                               encoding: .utf8)) == "seen-state")
            // The marker file is not a decodable conversation — remove it so
            // the manager-bound sections construct against a clean root
            // instead of logging decode noise.
            try? FileManager.default.removeItem(at: conversationFile)

            // 3b. Untrusted archives (Codex, Release B round 1): restore is
            // policy-aware — an old backup's 0644 files land 0600, harness
            // directories 0700, a reminder script keeps owner exec, projects/
            // keeps its archived modes; a symlink at a harness-owned path
            // (conversation.json, archive/) is refused at staging with the
            // current state untouched; a symlink inside user content is
            // restored as a link.
            do {
                let fm = FileManager.default
                func lmode(_ path: String) -> Int {
                    var st = stat()
                    guard lstat(path, &st) == 0 else { return -1 }
                    return Int(st.st_mode & 0o7777)
                }
                func isLink(_ path: String) -> Bool {
                    var st = stat()
                    return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
                }
                func runTool(_ tool: String, _ args: [String], cwd: URL? = nil) throws -> Int32 {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: tool)
                    p.arguments = args
                    p.currentDirectoryURL = cwd
                    p.standardOutput = FileHandle.nullDevice
                    p.standardError = FileHandle.nullDevice
                    try p.run(); p.waitUntilExit()
                    return p.terminationStatus
                }
                func makeArchive(_ name: String, _ build: (URL) throws -> Void) throws -> URL {
                    let stage = tempRoot.appendingPathComponent("stage-\(name)", isDirectory: true)
                    try fm.createDirectory(at: stage, withIntermediateDirectories: true)
                    _ = try runTool(archiveTool("unzip")!, ["-q", backup.path, "-d", stage.path])
                    try build(stage)
                    let out = tempRoot.appendingPathComponent("\(name).mind")
                    _ = try runTool(archiveTool("zip")!, ["-r", "-q", "-y", out.path, "."], cwd: stage)
                    return out
                }
                let external = tempRoot.appendingPathComponent("external-target", isDirectory: true)
                try fm.createDirectory(at: external, withIntermediateDirectories: true)
                try "EXTERNAL".write(to: external.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)

                // (a) old backup with wide modes
                let old = try makeArchive("old-modes") { stage in
                    _ = chmod(stage.appendingPathComponent("conversation.json").path, 0o644)
                    let archiveDir = stage.appendingPathComponent("archive", isDirectory: true)
                    try fm.createDirectory(at: archiveDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
                    try "{}".write(to: archiveDir.appendingPathComponent("2026-01.json"), atomically: true, encoding: .utf8)
                    _ = chmod(archiveDir.appendingPathComponent("2026-01.json").path, 0o644)
                    _ = chmod(stage.appendingPathComponent("documents/doc.txt").path, 0o644)
                    _ = chmod(stage.appendingPathComponent("reminder-scripts/\(watcherId.uuidString).sh").path, 0o755)
                    let proj = stage.appendingPathComponent("projects/p", isDirectory: true)
                    try fm.createDirectory(at: proj, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
                    try "#!/bin/sh\n".write(to: proj.appendingPathComponent("build.sh"), atomically: true, encoding: .utf8)
                    _ = chmod(proj.appendingPathComponent("build.sh").path, 0o755)
                    let link = stage.appendingPathComponent("documents/linked.txt")
                    symlink(external.appendingPathComponent("secret.txt").path, link.path)
                }
                let stagedOld = try await MindExportService.shared.stageMind(from: old)
                try await MindExportService.shared.applyStagedMind(stagedOld)
                check("3b.1 old backup: conversation.json restored 0600 (was 0644 in the archive)",
                      lmode(conversationFile.path) == 0o600, String(lmode(conversationFile.path), radix: 8))
                let archiveDirDest = dataRoot.appendingPathComponent("archive")
                check("3b.2 old backup: archive/ 0700 and its file 0600",
                      lmode(archiveDirDest.path) == 0o700 && lmode(archiveDirDest.appendingPathComponent("2026-01.json").path) == 0o600,
                      "\(String(lmode(archiveDirDest.path), radix: 8)) \(String(lmode(archiveDirDest.appendingPathComponent("2026-01.json").path), radix: 8))")
                check("3b.3 old backup: reminder script 0700 (owner exec kept, group/other dropped)",
                      lmode(scriptFile.path) == 0o700, String(lmode(scriptFile.path), radix: 8))
                let projFile = dataRoot.appendingPathComponent("projects/p/build.sh")
                check("3b.4 old backup: projects/ file keeps its archived 0755",
                      lmode(projFile.path) == 0o755, String(lmode(projFile.path), radix: 8))
                let docLink = documentsDir.appendingPathComponent("linked.txt")
                check("3b.5 old backup: a symlink inside documents/ is restored as a link",
                      isLink(docLink.path) && lmode(external.appendingPathComponent("secret.txt").path) == 0o644)
                try? fm.removeItem(at: conversationFile)

                // (b) symlinked conversation.json → refused, current state untouched
                try "CURRENT".write(to: conversationFile, atomically: true, encoding: .utf8)
                let hostileConv = try makeArchive("hostile-conv") { stage in
                    let conv = stage.appendingPathComponent("conversation.json")
                    try fm.removeItem(at: conv)
                    symlink(external.appendingPathComponent("secret.txt").path, conv.path)
                }
                var refusedConv = false
                var refusalText = ""
                do { _ = try await MindExportService.shared.stageMind(from: hostileConv) }
                catch let error as MindExportError {
                    if case .unsafeArchive(let what) = error { refusedConv = true; refusalText = what }
                }
                check("3b.6 archive with a symlinked conversation.json is refused at staging",
                      refusedConv && refusalText.contains("conversation.json"), refusalText)
                check("3b.7 current conversation untouched by the refused import",
                      (try? String(contentsOf: conversationFile, encoding: .utf8)) == "CURRENT" && !isLink(conversationFile.path))

                // (c) symlinked archive/ directory → refused
                let hostileDir = try makeArchive("hostile-archive-dir") { stage in
                    let archiveDir = stage.appendingPathComponent("archive")
                    try? fm.removeItem(at: archiveDir)
                    symlink(external.path, archiveDir.path)
                }
                var refusedDir = false
                do { _ = try await MindExportService.shared.stageMind(from: hostileDir) }
                catch let error as MindExportError { if case .unsafeArchive = error { refusedDir = true } }
                check("3b.8 archive with a symlinked archive/ directory is refused at staging", refusedDir)
                // (d) wrong object kinds and a dangling link at harness paths
                try "CURRENT2".write(to: conversationFile, atomically: true, encoding: .utf8)
                let currentArchive = dataRoot.appendingPathComponent("archive", isDirectory: true)
                try? fm.createDirectory(at: currentArchive, withIntermediateDirectories: true)
                try "keep".write(to: currentArchive.appendingPathComponent("keep.json"), atomically: true, encoding: .utf8)
                func refusedAtStaging(_ archive: URL) async -> String? {
                    do { _ = try await MindExportService.shared.stageMind(from: archive); return nil }
                    catch let error as MindExportError {
                        if case .unsafeArchive(let what) = error { return what }
                        return "other error: \(error)"
                    } catch { return "other error: \(error)" }
                }
                let dirConv = try makeArchive("conv-is-dir") { stage in
                    let conv = stage.appendingPathComponent("conversation.json")
                    try fm.removeItem(at: conv)
                    try fm.createDirectory(at: conv, withIntermediateDirectories: true)
                    try "x".write(to: conv.appendingPathComponent("inner"), atomically: true, encoding: .utf8)
                }
                let dirConvWhy = await refusedAtStaging(dirConv)
                check("3b.10 conversation.json as a directory is refused at staging",
                      dirConvWhy?.contains("must be a regular file") == true, dirConvWhy ?? "accepted")
                let fileArchive = try makeArchive("archive-is-file") { stage in
                    let archiveDir = stage.appendingPathComponent("archive")
                    try? fm.removeItem(at: archiveDir)
                    try "not a dir".write(to: archiveDir, atomically: true, encoding: .utf8)
                }
                let fileArchiveWhy = await refusedAtStaging(fileArchive)
                check("3b.11 archive as a regular file is refused at staging",
                      fileArchiveWhy?.contains("must be a directory") == true, fileArchiveWhy ?? "accepted")
                let danglingConv = try makeArchive("conv-dangling") { stage in
                    let conv = stage.appendingPathComponent("conversation.json")
                    try fm.removeItem(at: conv)
                    symlink("/nonexistent/target", conv.path)
                }
                let danglingWhy = await refusedAtStaging(danglingConv)
                check("3b.12 a dangling symlink at conversation.json is detected (lstat), not treated as absent",
                      danglingWhy?.contains("must be a regular file") == true, danglingWhy ?? "accepted")
                check("3b.13 current conversation and archive/ untouched by the three refusals",
                      (try? String(contentsOf: conversationFile, encoding: .utf8)) == "CURRENT2"
                      && (try? String(contentsOf: currentArchive.appendingPathComponent("keep.json"), encoding: .utf8)) == "keep")
                check("3b.9 no staged temp directory left behind by the refusals",
                      ((try? fm.contentsOfDirectory(atPath: tempRoot.path)) ?? []).filter { UUID(uuidString: $0) != nil }.isEmpty)
                try? fm.removeItem(at: conversationFile)
            }

            // 3a-bis. A failed export must never destroy an existing backup
            // (Codex, 2026-08-27): the destination is untouched until a
            // complete archive exists, and the rename(2) swap is atomic —
            // no partial or sibling temp file may remain.
            let exportDestDir = tempRoot.appendingPathComponent("export-dest", isDirectory: true)
            try FileManager.default.createDirectory(at: exportDestDir, withIntermediateDirectories: true)
            let exportDest = exportDestDir.appendingPathComponent("backup.mind")
            let priorContent = Data("precious existing backup".utf8)
            try priorContent.write(to: exportDest)

            await MindExportService.shared._testInjectZipFailure(true)
            var exportThrew = false
            do { try await MindExportService.shared.exportMind(to: exportDest) }
            catch { exportThrew = true }
            await MindExportService.shared._testInjectZipFailure(false)
            check("failed export throws instead of pretending", exportThrew)
            check("existing backup survives a failed export byte-identical",
                  (try? Data(contentsOf: exportDest)) == priorContent)
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: exportDestDir.path)) ?? []
            check("failed export leaves no partial or sibling file at the destination",
                  leftovers == ["backup.mind"], "\(leftovers)")

            var replaceSucceeded = false
            do {
                try await MindExportService.shared.exportMind(to: exportDest)
                replaceSucceeded = true
            } catch {}
            var stagedOK = false
            if replaceSucceeded, let restaged = try? await MindExportService.shared.stageMind(from: exportDest) {
                stagedOK = true
                await MindExportService.shared.discardStagedMind(restaged)
            }
            check("successful export atomically replaces the old backup with a valid archive",
                  replaceSucceeded && stagedOK && (try? Data(contentsOf: exportDest)) != priorContent,
                  "succeeded=\(replaceSucceeded) staged=\(stagedOK)")

            // 3a-ter. LITE export (owner, 2026-08-27): memory only — the
            // payload folders are skipped, everything else rides along.
            for payload in ["images", "tool_attachments", "projects", "research"] {
                let dir = dataRoot.appendingPathComponent(payload, isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try Data("payload marker".utf8).write(to: dir.appendingPathComponent("marker.bin"))
            }
            let liteDest = exportDestDir.appendingPathComponent("lite.mind")
            try await MindExportService.shared.exportMind(to: liteDest, scope: .lite)
            let liteStaged = try await MindExportService.shared.stageMind(from: liteDest)
            let missingPayload = MindExportService.ExportScope.payloadFolderNames.allSatisfy {
                !FileManager.default.fileExists(atPath: liteStaged.tempDir.appendingPathComponent($0).path)
            }
            check("lite export carries no payload folders (documents/images/attachments/projects/research)",
                  missingPayload)
            check("lite export still carries the watcher scripts and archive memory",
                  FileManager.default.fileExists(atPath: liteStaged.tempDir.appendingPathComponent("reminder-scripts").path)
                      && FileManager.default.fileExists(atPath: liteStaged.tempDir.appendingPathComponent("mind_config.json").path))
            await MindExportService.shared.discardStagedMind(liteStaged)
            for payload in ["images", "tool_attachments", "projects", "research"] {
                try? FileManager.default.removeItem(at: dataRoot.appendingPathComponent(payload, isDirectory: true))
            }

            // 3a-quater. Replacement metadata (Codex, 2026-08-27): a backup
            // whose config carries an EMPTY description map and NO persona
            // must clear the destination's — not silently preserve the
            // previous Mind's cached file memories or stored name. Seeds the
            // destination, imports an empty-source lite backup, verifies
            // payload AND metadata are gone.
            hermeticGuard: do {
                // The description store is the injected test file (set at
                // suite start), so nothing here can touch the machine's
                // real preferences even through a crash or watchdog kill.
                // If that wiring is ever lost, fail loudly and run NONE of
                // the mutations — never write the machine's real store.
                check("description store is hermetic before the test mutates it",
                      FileDescriptionsStore.isHermetic)
                guard FileDescriptionsStore.isHermetic else { break hermeticGuard }
                // Build the "fresh Briglia" source backup: no descriptions, no
                // persona.
                try FileDescriptionsStore.storeData(
                    try JSONEncoder().encode([String: String]()))
                try KeychainHelper.saveBatch([
                    KeychainHelper.assistantNameKey: nil,
                    KeychainHelper.userNameKey: nil,
                    KeychainHelper.userContextKey: nil,
                    KeychainHelper.structuredUserContextKey: nil,
                ])
                let emptySource = exportDestDir.appendingPathComponent("empty-lite.mind")
                try await MindExportService.shared.exportMind(to: emptySource, scope: .lite)

                // Seed the DESTINATION with the previous Mind's leftovers.
                let staleDescriptions = ["ghost.pdf": "stale description of a file that no longer exists"]
                try FileDescriptionsStore.storeData(
                    try JSONEncoder().encode(staleDescriptions))
                try KeychainHelper.saveBatch([
                    KeychainHelper.assistantNameKey: "OldAda",
                    KeychainHelper.userNameKey: "Previous Owner",
                    KeychainHelper.userContextKey: "context from the previous mind",
                    KeychainHelper.structuredUserContextKey: "structured context from the previous mind",
                ])
                try FileManager.default.createDirectory(at: documentsDir, withIntermediateDirectories: true)
                let ghostDoc = documentsDir.appendingPathComponent("ghost.pdf")
                try Data("ghost payload".utf8).write(to: ghostDoc)

                let emptyStaged = try await MindExportService.shared.stageMind(from: emptySource)
                try await MindExportService.shared.applyStagedMind(emptyStaged)

                check("empty-source apply clears the destination's payload document",
                      !FileManager.default.fileExists(atPath: ghostDoc.path))
                let descriptionsAfter = FileDescriptionsStore.loadData()
                    .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
                check("empty-source apply REPLACES file descriptions with {}",
                      descriptionsAfter?.isEmpty == true,
                      String(describing: descriptionsAfter))
                let survivingPersona = [
                    KeychainHelper.assistantNameKey, KeychainHelper.userNameKey,
                    KeychainHelper.userContextKey, KeychainHelper.structuredUserContextKey
                ].compactMap { KeychainHelper.load(key: $0) }
                check("empty-source apply deletes the destination's persona fields",
                      survivingPersona.isEmpty, "\(survivingPersona)")
            }
        } else {
            print("⚠ SKIP: zip/unzip not installed — round-trip checks skipped")
        }

        // 3b. Staged watcher preparation (Codex rounds 1–4, 2026-08-27):
        // rebase + quarantine happen IN THE STAGED reminders.json with
        // checked persistence, BEFORE anything destructive — the mutated
        // staged file is what applyStagedMind copies into place, so a
        // write failure rejects the archive instead of restoring unpaused
        // rows. No zip needed: this operates on a bare staged tree.
        do {
            let stagedRoot = tempRoot.appendingPathComponent("staged-mind", isDirectory: true)
            let stagedScripts = stagedRoot.appendingPathComponent("reminder-scripts", isDirectory: true)
            try FileManager.default.createDirectory(at: stagedScripts, withIntermediateDirectories: true)
            let watcherId = UUID()
            let scriptSource = "echo staged-check"
            try scriptSource.write(
                to: stagedScripts.appendingPathComponent("\(watcherId.uuidString).sh"),
                atomically: true, encoding: .utf8)
            let scriptSHA = SHA256.hash(data: Data(scriptSource.utf8))
                .map { String(format: "%02x", $0) }.joined()
            let foreignPath = "/home/other-user/.local/share/briglia/reminder-scripts/\(watcherId.uuidString).sh"
            let scripted = Reminder(
                id: watcherId,
                triggerDate: Date().addingTimeInterval(3600),
                prompt: "staged rebase watcher",
                recurrence: .custom(minutes: 60),
                scriptPath: foreignPath,
                scriptSHA256: scriptSHA)
            let plain = Reminder(
                triggerDate: Date().addingTimeInterval(3600),
                prompt: "plain code-free reminder")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let stagedRemindersFile = stagedRoot.appendingPathComponent("reminders.json")
            try (try encoder.encode([scripted, plain])).write(to: stagedRemindersFile)

            let quarantined = try ReminderService.prepareStagedReminders(stagedRoot: stagedRoot)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let rows = try decoder.decode([Reminder].self, from: Data(contentsOf: stagedRemindersFile))
            let scriptedRow = rows.first { $0.id == watcherId }
            let localExpected = StoragePaths.dataRoot
                .appendingPathComponent("reminder-scripts", isDirectory: true)
                .appendingPathComponent("\(watcherId.uuidString).sh").path
            check("staged prepare rebases the foreign script path onto this install",
                  scriptedRow?.scriptPath == localExpected,
                  scriptedRow?.scriptPath ?? "nil")
            check("staged prepare quarantines the scripted row durably (paused + provenance)",
                  quarantined == 1 && scriptedRow?.paused == true && scriptedRow?.importQuarantined == true,
                  "quarantined=\(quarantined) paused=\(String(describing: scriptedRow?.paused)) flag=\(String(describing: scriptedRow?.importQuarantined))")
            let plainRow = rows.first { $0.id == plain.id }
            check("staged prepare leaves the code-free plain reminder armed",
                  plainRow != nil && plainRow?.paused != true && plainRow?.importQuarantined != true)

            // Undecodable reminders.json must THROW — the import then
            // rejects the archive instead of applying rows it could not
            // quarantine.
            try Data("not valid json".utf8).write(to: stagedRemindersFile)
            var threwOnCorrupt = false
            do { _ = try ReminderService.prepareStagedReminders(stagedRoot: stagedRoot) }
            catch { threwOnCorrupt = true }
            check("staged prepare throws on an unreadable reminders.json", threwOnCorrupt)

            // Older backups without reminders.json are fine: zero quarantined.
            try FileManager.default.removeItem(at: stagedRemindersFile)
            let none = try ReminderService.prepareStagedReminders(stagedRoot: stagedRoot)
            check("staged prepare tolerates a backup with no reminders.json", none == 0, "\(none)")
        }

        // 3c. Quarantine enforcement on the LIVE service (Codex round 4):
        // durable provenance means the agent-facing resume refuses, and
        // only the user-typed /resumewatcher path (resumeImportedWatcher)
        // re-arms — with checked persistence, and a hash-mismatched script
        // stays quarantined even through a user approval attempt.
        do {
            let dataRoot = StoragePaths.dataRoot
            let scriptsDir = dataRoot.appendingPathComponent("reminder-scripts", isDirectory: true)
            try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
            let goodId = UUID()
            let tamperedId = UUID()
            let failInjectId = UUID()
            let goodSource = "echo good-check"
            let goodSHA = SHA256.hash(data: Data(goodSource.utf8))
                .map { String(format: "%02x", $0) }.joined()
            for id in [goodId, failInjectId] {
                try goodSource.write(
                    to: scriptsDir.appendingPathComponent("\(id.uuidString).sh"),
                    atomically: true, encoding: .utf8)
            }
            // The tampered row carries goodSHA but different bytes on disk.
            try "echo tampered-content".write(
                to: scriptsDir.appendingPathComponent("\(tamperedId.uuidString).sh"),
                atomically: true, encoding: .utf8)
            func quarantinedRow(id: UUID, prompt: String) -> Reminder {
                var row = Reminder(
                    id: id,
                    triggerDate: Date().addingTimeInterval(3600),
                    prompt: prompt,
                    recurrence: .custom(minutes: 60),
                    scriptPath: scriptsDir.appendingPathComponent("\(id.uuidString).sh").path,
                    scriptSHA256: goodSHA)
                row.paused = true
                row.importQuarantined = true
                return row
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try (try encoder.encode([
                quarantinedRow(id: goodId, prompt: "good imported watcher"),
                quarantinedRow(id: tamperedId, prompt: "tampered imported watcher"),
                quarantinedRow(id: failInjectId, prompt: "write-failure imported watcher")
            ])).write(to: dataRoot.appendingPathComponent("reminders.json"))
            await ReminderService.shared.reloadFromDisk()

            var agentRefused = false
            var agentMessage = ""
            if case .failure(let error) = await ReminderService.shared.resumeScriptedReminder(id: goodId) {
                agentRefused = true
                agentMessage = error.message
            }
            check("agent-facing resume refuses an import-quarantined watcher and points at /resumewatcher",
                  agentRefused && agentMessage.contains("/resumewatcher"), agentMessage)

            var userApproved = false
            if case .success = await ReminderService.shared.resumeImportedWatcher(id: goodId) {
                userApproved = true
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let liveRows = try decoder.decode(
                [Reminder].self,
                from: Data(contentsOf: dataRoot.appendingPathComponent("reminders.json")))
            let approvedRow = liveRows.first { $0.id == goodId }
            check("user /resumewatcher approval re-arms and clears the quarantine durably",
                  userApproved && approvedRow?.paused != true && approvedRow?.importQuarantined != true,
                  "approved=\(userApproved) paused=\(String(describing: approvedRow?.paused)) flag=\(String(describing: approvedRow?.importQuarantined))")

            // Injected write failure (Codex round 5): the approval is ONE
            // checked transaction — the in-memory resume persists nothing,
            // so when the single checked save throws, memory rolls back to
            // quarantined and disk (never written in the flow) still holds
            // the quarantined row. No path may leave an active watcher on
            // disk while reporting it quarantined.
            await ReminderService.shared._testInjectCheckedSaveFailure(true)
            var injectedFailed = false
            var injectedMessage = ""
            if case .failure(let error) = await ReminderService.shared.resumeImportedWatcher(id: failInjectId) {
                injectedFailed = true
                injectedMessage = error.message
            }
            await ReminderService.shared._testInjectCheckedSaveFailure(false)
            let injectedRowsOnDisk = try decoder.decode(
                [Reminder].self,
                from: Data(contentsOf: dataRoot.appendingPathComponent("reminders.json")))
            let injectedDiskRow = injectedRowsOnDisk.first { $0.id == failInjectId }
            let injectedStillQuarantined = await ReminderService.shared.importQuarantinedWatchers()
                .contains { $0.id == failInjectId }
            check("a failed checked save rolls the approval back — memory AND disk stay quarantined",
                  injectedFailed && injectedMessage.contains("stays quarantined")
                      && injectedStillQuarantined
                      && injectedDiskRow?.paused == true && injectedDiskRow?.importQuarantined == true,
                  "failed=\(injectedFailed) memQuarantined=\(injectedStillQuarantined) diskPaused=\(String(describing: injectedDiskRow?.paused)) diskFlag=\(String(describing: injectedDiskRow?.importQuarantined))")
            // …and the approval works once writes recover.
            var recovered = false
            if case .success = await ReminderService.shared.resumeImportedWatcher(id: failInjectId) {
                recovered = true
            }
            check("the approval succeeds after write recovery", recovered)

            var tamperedRefused = false
            if case .failure = await ReminderService.shared.resumeImportedWatcher(id: tamperedId) {
                tamperedRefused = true
            }
            let stillQuarantined = await ReminderService.shared.importQuarantinedWatchers()
                .contains { $0.id == tamperedId }
            check("a hash-mismatched imported watcher survives a failed approval still quarantined",
                  tamperedRefused && stillQuarantined,
                  "refused=\(tamperedRefused) stillQuarantined=\(stillQuarantined)")

            // Cleanup so later sections see no armed watcher.
            try? FileManager.default.removeItem(at: dataRoot.appendingPathComponent("reminders.json"))
            for id in [goodId, tamperedId, failInjectId] {
                try? FileManager.default.removeItem(at: scriptsDir.appendingPathComponent("\(id.uuidString).sh"))
            }
            await ReminderService.shared.reloadFromDisk()
        }

        // 4–7. Manager-bound checks (barrier, wipe abort, discard, ordering
        // regression) run on the MainActor like the manager itself; they
        // count their own failures and report the total back.
        failures += await managerChecks(tempRoot: tempRoot)

        if failures > 0 {
            print("MIND SELFTEST FAILED: \(failures) check(s) failed")
            throw ExitCode(1)
        }
        print("MIND SELFTEST PASSED")
    }

    /// Returns the number of failed checks in the MainActor-bound sections.
    @MainActor
    private func managerChecks(tempRoot: URL) async -> Int {
        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "✔" : "✖") \(label)\(ok || detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }
        func archiveTool(_ name: String) -> String? {
            var candidates = ["/usr/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
            if let path = ProcessInfo.processInfo.environment["PATH"] {
                candidates += path.split(separator: ":").map { "\($0)/\(name)" }
            }
            return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        }

        // 4. Quiescence barrier: registry subagents are cancelled AND
        // awaited; a stuck one aborts; a detached triage lane (outside the
        // registry) also refuses.
        do {
            let manager = ConversationManager()

            let clean = await manager.quiesceBackgroundWorkForMindRestore(timeoutSeconds: 1)
            check("barrier: quiescent system lets the import proceed",
                  clean == nil, clean ?? "")

            let stuckId = "mind-import-stuck-\(UUID().uuidString.prefix(8))"
            let stuck = Task<Void, Never> {
                let until = Date().addingTimeInterval(30)
                while Date() < until { usleep(50_000) }
                // Deliberately no _testUnregister: simulates a run that
                // never commits.
            }
            await SubagentBackgroundRegistry.shared._testRegister(id: stuckId, task: stuck)
            let busy = await manager.quiesceBackgroundWorkForMindRestore(timeoutSeconds: 0.5)
            check("barrier: stuck subagent reported at the deadline",
                  busy?.contains(stuckId) == true, busy ?? "nil")
            stuck.cancel()
            await SubagentBackgroundRegistry.shared._testUnregister(id: stuckId)

            let doneId = "mind-import-done-\(UUID().uuidString.prefix(8))"
            let started = Date()
            let finishing = Task<Void, Never> {
                // Cancellation-immune delay: quiesce cancels the task, but a
                // real subagent still takes time to reach its commit point.
                let until = Date().addingTimeInterval(0.6)
                while Date() < until { usleep(20_000) }
                await SubagentBackgroundRegistry.shared._testUnregister(id: doneId)
            }
            await SubagentBackgroundRegistry.shared._testRegister(id: doneId, task: finishing)
            let waited = await manager.quiesceBackgroundWorkForMindRestore(timeoutSeconds: 5)
            check("barrier: waits out a finishing subagent, then proceeds",
                  waited == nil && Date().timeIntervalSince(started) >= 0.5,
                  waited ?? "elapsed=\(Date().timeIntervalSince(started))")

            manager._testSetTriageLane("lane-test", inFlight: true)
            let triageBusy = await manager.quiesceBackgroundWorkForMindRestore(timeoutSeconds: 0.5)
            check("barrier: in-flight triage run refuses the import",
                  triageBusy?.contains("triage") == true, triageBusy ?? "nil")
            manager._testSetTriageLane("lane-test", inFlight: false)
            let triageClear = await manager.quiesceBackgroundWorkForMindRestore(timeoutSeconds: 1)
            check("barrier: cleared triage lane lets the import proceed",
                  triageClear == nil, triageClear ?? "")
        }

        // 4b. /exportmind's non-destructive consistency barrier: running
        // background writers refuse the export (nothing is cancelled for a
        // read-only backup); a clear system proceeds.
        do {
            let manager = ConversationManager()
            let clear = await manager.exportBusyReason(timeoutSeconds: 0.3)
            check("export barrier: quiet system lets the export proceed",
                  clear == nil, clear ?? "")

            let busyId = "export-busy-\(UUID().uuidString.prefix(8))"
            let busyTask = Task<Void, Never> {
                let until = Date().addingTimeInterval(30)
                while Date() < until { usleep(50_000) }
            }
            await SubagentBackgroundRegistry.shared._testRegister(id: busyId, task: busyTask)
            let subagentBusy = await manager.exportBusyReason(timeoutSeconds: 0.3)
            check("export barrier: running subagent refuses the export",
                  subagentBusy?.contains(busyId) == true, subagentBusy ?? "nil")
            check("export barrier refusal did not cancel the subagent",
                  !busyTask.isCancelled)
            busyTask.cancel()
            await SubagentBackgroundRegistry.shared._testUnregister(id: busyId)

            let job = await BashTools.runBackground(command: "sleep 300 # ada-mind-selftest-export")
            _ = job
            let jobBusy = await manager.exportBusyReason(timeoutSeconds: 0.3)
            check("export barrier: running bash job refuses the export",
                  jobBusy?.contains("background job") == true, jobBusy ?? "nil")
            _ = await BackgroundProcessRegistry.shared.purgeAllForWipe()

            manager._testSetTriageLane("lane-export-test", inFlight: true)
            let triageBusy = await manager.exportBusyReason(timeoutSeconds: 0.3)
            check("export barrier: in-flight triage run refuses the export",
                  triageBusy?.contains("triage") == true, triageBusy ?? "nil")
            manager._testSetTriageLane("lane-export-test", inFlight: false)
            let clearAgain = await manager.exportBusyReason(timeoutSeconds: 0.3)
            check("export barrier: cleared writers let the export proceed",
                  clearAgain == nil, clearAgain ?? "")
        }

        // 5. The wipe shared the triage gap (step 0b covers only the
        // registry): with a triage lane in flight, /deleteuserdata must
        // ABORT before touching anything.
        do {
            let manager = ConversationManager()
            manager.triageQuiesceTimeoutForTesting = 0.3
            manager._testSetTriageLane("lane-wipe-test", inFlight: true)
            let wipeFailures = await manager.deleteAllMemory()
            check("wipe: ABORTS while a triage run is in flight",
                  wipeFailures.first?.hasPrefix("ABORTED:") == true
                  && wipeFailures.first?.contains("triage") == true,
                  wipeFailures.joined(separator: "; "))
            manager._testSetTriageLane("lane-wipe-test", inFlight: false)
        }

        // 6. Pre-import outputs are DISCARDED once the import is committed:
        // a cancelled subagent's queued completion, a watcher check's
        // persisted fire, and the in-memory fallback fire all die with the
        // replaced Mind.
        do {
            let manager = ConversationManager()
            let completion = SubagentBackgroundRegistry.Completion(
                handle: .init(id: "subagent_import_test", subagentType: "general-purpose",
                              description: "pre-import result", startedAt: Date()),
                result: SubagentRunner.RunResult(
                    sessionId: "import-test-session", isNewSession: true,
                    finalMessage: "stale pre-import result", turnsUsed: 1,
                    toolsCalled: [], filesTouched: [], spendUSD: 0, error: nil),
                completedAt: Date())
            await SubagentBackgroundRegistry.shared._testEnqueueCompletion(completion)
            manager._testSeedPendingWatcherFire()
            let staleFire = FireRecord(watcherId: nil, source: .harness,
                                       content: "[stale pre-import fire]")
            check("discard setup: stale fire persisted", FireOutbox.persist(staleFire))

            await manager.discardPreImportBackgroundOutputs()

            let completionsLeft = await SubagentBackgroundRegistry.shared._testPendingCompletionsCount()
            check("discard: queued subagent completion dropped", completionsLeft == 0,
                  "left=\(completionsLeft)")
            check("discard: in-memory watcher fire dropped",
                  manager._testPendingWatcherFireCount() == 0)
            check("discard: FireOutbox pending records dropped",
                  FireOutbox.pending().isEmpty,
                  "pending=\(FireOutbox.pending().count)")
        }

        // 7. Ordering regression (Codex round 3 on the Ada.app arc): a
        // malformed archive must reject during the read-only STAGE step —
        // before the barrier cancels running subagents and before the
        // point-of-no-return discard destroys queued outputs.
        if let zip = archiveTool("zip"), archiveTool("unzip") != nil {
            let workDir = tempRoot.appendingPathComponent("mind-reject", isDirectory: true)
            try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            let payloadDir = workDir.appendingPathComponent("payload", isDirectory: true)
            try? FileManager.default.createDirectory(at: payloadDir, withIntermediateDirectories: true)
            try? Data("not a mind".utf8).write(to: payloadDir.appendingPathComponent("random.txt"))
            let badArchive = workDir.appendingPathComponent("bogus.mind")
            let zipProc = Process()
            zipProc.executableURL = URL(fileURLWithPath: zip)
            zipProc.currentDirectoryURL = payloadDir
            zipProc.arguments = ["-r", "-q", badArchive.path, "."]
            try? zipProc.run()
            zipProc.waitUntilExit()
            check("reject setup: non-Mind zip created",
                  zipProc.terminationStatus == 0
                  && FileManager.default.fileExists(atPath: badArchive.path))

            // Seed one output of every producer class the discard destroys.
            let manager = ConversationManager()
            let completion = SubagentBackgroundRegistry.Completion(
                handle: .init(id: "subagent_reject_test", subagentType: "general-purpose",
                              description: "live work", startedAt: Date()),
                result: SubagentRunner.RunResult(
                    sessionId: "reject-test-session", isNewSession: true,
                    finalMessage: "live result", turnsUsed: 1,
                    toolsCalled: [], filesTouched: [], spendUSD: 0, error: nil),
                completedAt: Date())
            await SubagentBackgroundRegistry.shared._testEnqueueCompletion(completion)
            manager._testSeedPendingWatcherFire()
            let liveFire = FireRecord(watcherId: nil, source: .harness,
                                      content: "[live fire]")
            check("reject setup: live fire persisted", FireOutbox.persist(liveFire))
            // A RUNNING subagent: rejection must not even cancel it (the
            // barrier — the first destructive step — must never run).
            let runningId = "reject-running-\(UUID().uuidString.prefix(8))"
            let runningTask = Task<Void, Never> {
                let until = Date().addingTimeInterval(30)
                while Date() < until { usleep(50_000) }
            }
            await SubagentBackgroundRegistry.shared._testRegister(id: runningId, task: runningTask)

            let outcome = await manager.performMindImport(from: badArchive, quiesceTimeoutSeconds: 0.5)
            var rejected = false
            if case .rejectedArchive = outcome { rejected = true }
            check("reject: non-Mind archive fails at the stage step",
                  rejected, "\(outcome)")
            let completionsLeft = await SubagentBackgroundRegistry.shared._testPendingCompletionsCount()
            check("reject: queued subagent completion survives", completionsLeft == 1,
                  "left=\(completionsLeft)")
            check("reject: in-memory watcher fire survives",
                  manager._testPendingWatcherFireCount() == 1)
            check("reject: FireOutbox record survives",
                  FireOutbox.pending().contains(where: { $0.id == liveFire.id }))
            check("reject: running subagent was never cancelled",
                  !runningTask.isCancelled)

            // 7b. Fingerprint pin: a confirm carrying the fingerprint of the
            // archive the user inspected must refuse a file that no longer
            // matches — BEFORE staging, with nothing touched.
            let pinned = await manager.performMindImport(
                from: badArchive, quiesceTimeoutSeconds: 0.5,
                expectedSHA256: String(repeating: "0", count: 64),
                expectedBytes: 1)
            var refusedChanged = false
            if case .rejectedArchive(let message) = pinned, message.contains("changed") {
                refusedChanged = true
            }
            check("fingerprint pin: swapped archive refuses with 'changed'",
                  refusedChanged, "\(pinned)")

            // Cleanup: drop everything this section seeded.
            runningTask.cancel()
            await SubagentBackgroundRegistry.shared._testUnregister(id: runningId)
            _ = await SubagentBackgroundRegistry.shared.drainCompletions()
            await manager.discardPreImportBackgroundOutputs()
        } else {
            print("⚠ SKIP: zip/unzip not installed — ordering-regression checks skipped")
        }

        return failures
    }
}
