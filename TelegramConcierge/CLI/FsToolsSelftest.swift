import ArgumentParser
import Foundation

/// Hidden deterministic test of the filesystem tools' model-facing contract:
/// tool-result JSON must show file content byte-faithfully (no `\/` escaping —
/// Foundation escapes forward slashes by default, which taught models to copy
/// `\/home\/...` into old_string), the escape-mismatch hint must cover the
/// `\/` failure mode, and the read-before-edit error must explain that the
/// read ledger resets across restarts. Section 9 covers the private-storage
/// policy the tools apply inside Briglia's roots (plan H2 d2/d3/d4). Operates
/// only on files inside a temp directory so it never disturbs a real
/// installation.
struct FsToolsSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__fstools-selftest",
        abstract: "Internal: verify filesystem tool JSON fidelity and edit diagnostics.",
        shouldDisplay: false
    )

    func run() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ada-fstools-selftest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        // Isolated XDG roots: section 8 exercises the harness secret store
        // through the file tools and must never touch a real installation.
        setenv("XDG_CONFIG_HOME", tempRoot.appendingPathComponent("config").path, 1)
        setenv("XDG_DATA_HOME", tempRoot.appendingPathComponent("data").path, 1)

        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "✔" : "✖") \(label)\(ok || detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }

        // 1. read_file returns slashes unescaped in the JSON the model sees.
        let slashFile = tempRoot.appendingPathComponent("paths.txt").path
        let slashContent = "source=/home/phablet/video.qml\ndest=/usr/local/share\n"
        try slashContent.write(toFile: slashFile, atomically: true, encoding: .utf8)
        let readResult = await FilesystemTools.shared.readFile(path: slashFile)
        check("read_file result contains plain /home/phablet path",
              readResult.content.contains("/home/phablet/video.qml"))
        check("read_file result contains no escaped slashes",
              !readResult.content.contains("\\/"), String(readResult.content.prefix(200)))

        // 2. write_file / edit_file result JSON (paths, diffs) also unescaped.
        let writeResult = await FilesystemTools.shared.writeFile(
            path: tempRoot.appendingPathComponent("w.txt").path, content: "a/b/c\n")
        check("write_file result contains no escaped slashes",
              !writeResult.content.contains("\\/"), String(writeResult.content.prefix(200)))
        let editOK = await FilesystemTools.shared.editFile(
            path: slashFile, oldString: "/usr/local/share", newString: "/opt/share")
        check("edit_file success result contains no escaped slashes",
              !editOK.content.contains("\\/"), String(editOK.content.prefix(200)))

        // 3. The \/ footgun itself: old_string copied from JSON-escaped display
        //    fails the match but now gets the escape-mismatch hint.
        let editEscaped = await FilesystemTools.shared.editFile(
            path: slashFile, oldString: "source=\\/home\\/phablet\\/video.qml", newString: "x")
        check("escaped-slash old_string fails with re-read hint",
              editEscaped.content.contains("old_string not found")
              && editEscaped.content.contains("Hint")
              && editEscaped.content.contains("exact bytes"), String(editEscaped.content.prefix(300)))

        // 4. Existing hint behavior preserved: literal \n where the file has newlines.
        let editNewline = await FilesystemTools.shared.editFile(
            path: slashFile, oldString: "video.qml\\ndest=", newString: "x")
        check("escaped-newline old_string still hints",
              editNewline.content.contains("Hint") && editNewline.content.contains("exact bytes"),
              String(editNewline.content.prefix(300)))

        // 5. A genuinely absent string gets no hint (message stays clean).
        let editAbsent = await FilesystemTools.shared.editFile(
            path: slashFile, oldString: "not in the file at all", newString: "x")
        check("plain no-match carries no escape hint",
              editAbsent.content.contains("old_string not found")
              && !editAbsent.content.contains("Hint"), String(editAbsent.content.prefix(300)))

        // 6. escapeMismatchHint unit checks, including the new "/" table entry.
        check("hint unit: \\/ in old_string vs plain source",
              EditStrategies.escapeMismatchHint(source: "path /a/b end",
                                                oldString: "path \\/a\\/b end") != nil)
        check("hint unit: no false positive on matching plain strings",
              EditStrategies.escapeMismatchHint(source: "plain text", oldString: "other text") == nil)

        // 7. Read-before-edit error explains the ledger reset (restart testimony).
        let freshFile = tempRoot.appendingPathComponent("unread.txt").path
        try "hello\n".write(toFile: freshFile, atomically: true, encoding: .utf8)
        let editUnread = await FilesystemTools.shared.editFile(
            path: freshFile, oldString: "hello", newString: "ciao")
        check("edit of never-read file mentions ledger reset on restart",
              editUnread.content.contains("read_file first")
              && editUnread.content.contains("restart"), String(editUnread.content.prefix(300)))

        // 8. Harness secret store through the file tools (HarnessSecretStore):
        //    the Telegram bot token is masked on read and its field is
        //    refused on edit; every other field stays editable; whole-file
        //    rewrites are refused; files elsewhere are untouched by the rules.
        let token = "5551234567:AAGoldenTokenValue_0123456789abcdef"
        let serperV1 = "serper-visible-key-abcdef0123"
        let opencodeKey = "sk-opencode-visible-0123456789"
        try KeychainHelper.save(key: KeychainHelper.telegramBotTokenKey, value: token)
        try KeychainHelper.save(key: KeychainHelper.serperApiKeyKey, value: serperV1)
        try KeychainHelper.save(key: ProviderProfiles.opencodeApiKeyKey, value: opencodeKey)
        let storePath = HarnessSecretStore.storePath
        check("secret store resolved under the isolated config root",
              StoragePaths.configRoot.path.hasPrefix(tempRoot.path), storePath)
        func rawStore() -> String { (try? String(contentsOfFile: storePath, encoding: .utf8)) ?? "" }
        func storedToken() -> String? {
            (try? Data(contentsOf: URL(fileURLWithPath: storePath)))
                .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }?[KeychainHelper.telegramBotTokenKey]
        }
        func succeeded(_ r: FilesystemTools.OpResult) -> Bool {
            ((try? JSONSerialization.jsonObject(with: Data(r.content.utf8))) as? [String: Any])?["success"] as? Bool == true
        }
        let storeRead = await FilesystemTools.shared.readFile(path: storePath)
        check("read_file masks the Telegram bot token",
              storeRead.content.contains(HarnessSecretStore.tokenPlaceholder) && !storeRead.content.contains(token),
              String(storeRead.content.prefix(300)))
        check("read_file returns the other keys verbatim",
              storeRead.content.contains(serperV1) && storeRead.content.contains(opencodeKey))
        let serperV2 = "serper-visible-key-ghijkl4567"
        let editSerper = await FilesystemTools.shared.editFile(path: storePath, oldString: serperV1, newString: serperV2)
        check("edit_file of the Serper key succeeds", succeeded(editSerper), String(editSerper.content.prefix(300)))
        check("...and the stored token is byte-identical afterwards",
              storedToken() == token && rawStore().contains(serperV2))
        let editPlaceholder = await FilesystemTools.shared.editFile(
            path: storePath, oldString: serperV2, newString: HarnessSecretStore.tokenPlaceholder)
        check("edit_file writing a [REDACTED:…] placeholder back is refused",
              !succeeded(editPlaceholder) && editPlaceholder.content.contains("placeholder"),
              String(editPlaceholder.content.prefix(300)))
        let editTokenField = await FilesystemTools.shared.editFile(
            path: storePath, oldString: "\"\(KeychainHelper.telegramBotTokenKey)\"", newString: "\"telegram_bot_token_old\"")
        check("edit_file touching the token field is refused",
              !succeeded(editTokenField) && editTokenField.content.contains("/switchbot"),
              String(editTokenField.content.prefix(300)))
        let editTokenValue = await FilesystemTools.shared.editFile(path: storePath, oldString: token, newString: "x")
        check("edit_file touching the token value is refused", !succeeded(editTokenValue))
        let writeStore = await FilesystemTools.shared.writeFile(path: storePath, content: "{}\n")
        check("write_file on the secret store is refused",
              !succeeded(writeStore) && writeStore.content.contains("whole-file"),
              String(writeStore.content.prefix(300)))
        check("...and the store is unchanged", storedToken() == token && rawStore().contains(serperV2))
        // apply_patch: a hunk on the Serper line applies; hunks on the token
        // field, deletes and moves are refused.
        let serperLine = rawStore().components(separatedBy: "\n").first { $0.contains(serperV2) } ?? ""
        let serperV3 = "serper-visible-key-mnopqr8901"
        let patchSerper = await ApplyPatch.run(patchText: """
        *** Begin Patch
        *** Update File: \(storePath)
        @@
        -\(serperLine)
        +\(serperLine.replacingOccurrences(of: serperV2, with: serperV3))
        *** End Patch
        """)
        check("apply_patch of the Serper key succeeds",
              !patchSerper.content.contains("\"error\"") && rawStore().contains(serperV3),
              String(patchSerper.content.prefix(300)))
        check("...and the stored token is byte-identical after the patch", storedToken() == token)
        let tokenLine = rawStore().components(separatedBy: "\n").first { $0.contains("\"\(KeychainHelper.telegramBotTokenKey)\"") } ?? ""
        let patchToken = await ApplyPatch.run(patchText: """
        *** Begin Patch
        *** Update File: \(storePath)
        @@
        -\(tokenLine)
        +\(tokenLine.replacingOccurrences(of: token, with: "1:new"))
        *** End Patch
        """)
        check("apply_patch touching the token field is refused",
              patchToken.content.contains("\"error\"") && patchToken.content.contains("/switchbot") && storedToken() == token,
              String(patchToken.content.prefix(300)))
        let patchDelete = await ApplyPatch.run(patchText: "*** Begin Patch\n*** Delete File: \(storePath)\n*** End Patch")
        check("apply_patch deleting the secret store is refused",
              patchDelete.content.contains("\"error\"") && FileManager.default.fileExists(atPath: storePath),
              String(patchDelete.content.prefix(300)))
        // Post-edit invariant (Codex review 2026-09-02): edits that overlap the
        // token or its field name WITHOUT containing either in full are refused
        // on the result — substring of the token, substring of the field name,
        // a batch with one such edit, and replace_all over a fragment.
        let tokenFragment = String(token.dropFirst(12).prefix(10))
        let subToken = await FilesystemTools.shared.editFile(path: storePath, oldString: tokenFragment, newString: "XXXXXXXXXX")
        check("edit_file over a substring of the token is refused", !succeeded(subToken) && storedToken() == token,
              String(subToken.content.prefix(300)))
        let subField = await FilesystemTools.shared.editFile(path: storePath, oldString: "bot_token", newString: "bot_tok")
        check("edit_file over a substring of the token field name is refused", !succeeded(subField) && storedToken() == token,
              String(subField.content.prefix(300)))
        let batch = await FilesystemTools.shared.editFile(path: storePath, edits: [
            FilesystemTools.EditPair(oldString: serperV3, newString: "serper-visible-key-batch00001"),
            FilesystemTools.EditPair(oldString: tokenFragment, newString: "YYYYYYYYYY"),
        ])
        check("batched edit_file with one edit inside the token is refused as a whole",
              !succeeded(batch) && storedToken() == token && rawStore().contains(serperV3),
              String(batch.content.prefix(300)))
        let replaceAll = await FilesystemTools.shared.editFile(path: storePath, oldString: "0123", newString: "9876", replaceAll: true)
        check("replace_all over a fragment shared with the token is refused", !succeeded(replaceAll) && storedToken() == token,
              String(replaceAll.content.prefix(300)))
        let breakJSON = await FilesystemTools.shared.editFile(path: storePath, oldString: "{", newString: "[")
        check("edit_file that leaves the store non-JSON is refused", !succeeded(breakJSON) && storedToken() == token,
              String(breakJSON.content.prefix(300)))
        let fragLine = rawStore().components(separatedBy: "\n").first { $0.contains(token) } ?? ""
        let patchSub = await ApplyPatch.run(patchText: """
        *** Begin Patch
        *** Update File: \(storePath)
        @@
        -\(fragLine)
        +\(fragLine.replacingOccurrences(of: tokenFragment, with: "ZZZZZZZZZZ"))
        *** End Patch
        """)
        check("apply_patch changing the token line is refused on the result", patchSub.content.contains("\"error\"") && storedToken() == token,
              String(patchSub.content.prefix(300)))

        // The rules are scoped to the harness store: a user .env elsewhere is untouched.
        let envPath = tempRoot.appendingPathComponent("project.env").path
        let envWrite = await FilesystemTools.shared.writeFile(
            path: envPath, content: "TOKEN=\(HarnessSecretStore.tokenPlaceholder)\nBOT=\(token)\n")
        check("write_file on a user .env with the same strings is allowed", succeeded(envWrite),
              String(envWrite.content.prefix(300)))
        let envRead = await FilesystemTools.shared.readFile(path: envPath)
        check("read_file on a user .env is not masked", envRead.content.contains(token))
        let envEdit = await FilesystemTools.shared.editFile(path: envPath, oldString: "BOT=\(token)", newString: "BOT=other")
        check("edit_file on a user .env touching the token string is allowed", succeeded(envEdit),
              String(envEdit.content.prefix(300)))


        // 9. Private-by-default storage (plan H2, tests d2/d3/d4): inside the
        //    roots the file tools apply the policy — owner bits kept, group/other
        //    stripped, symlinks resolved and classified — and outside the roots
        //    (or in projects/) the user's files keep their exact modes.
        umask(0o022)  // the policy, not the environment, decides the modes asserted below
        let fm = FileManager.default
        let configRoot = StoragePaths.configRoot
        let dataRoot = StoragePaths.dataRoot
        func mode(_ path: String) -> Int {
            var st = stat()
            guard lstat(path, &st) == 0 else { return -1 }
            return Int(st.st_mode & 0o7777)
        }
        func octal(_ m: Int) -> String { m < 0 ? "absent" : String(m, radix: 8) }
        func isLink(_ path: String) -> Bool {
            var st = stat()
            return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
        }
        func contents(_ path: String) -> String {
            (try? String(contentsOfFile: path, encoding: .utf8)) ?? "<unreadable>"
        }
        func plant(_ path: String, _ text: String, _ m: Int) throws {
            try fm.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(toFile: path, atomically: false, encoding: .utf8)
            _ = chmod(path, mode_t(m))
        }
        func link(_ at: String, to target: String) throws {
            try fm.createDirectory(at: URL(fileURLWithPath: at).deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: at, withDestinationPath: target)
        }
        /// Runs a shell script by its own path (needs the exec bit) and returns stdout.
        func execute(_ path: String) -> String {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: path)
            let out = Pipe()
            proc.standardOutput = out
            proc.standardError = FileHandle.nullDevice
            do { try proc.run() } catch { return "<exec failed: \(error.localizedDescription)>" }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func script(_ tag: String) -> String { "#!/bin/sh\necho \(tag)\n" }
        func errorText(_ r: FilesystemTools.OpResult) -> String {
            ((try? JSONSerialization.jsonObject(with: Data(r.content.utf8))) as? [String: Any])?["error"] as? String ?? ""
        }
        let outside = tempRoot.appendingPathComponent("outside").path
        let external = tempRoot.appendingPathComponent("external").path
        check("9.0 test roots are the isolated XDG roots",
              configRoot.path.hasPrefix(tempRoot.path) && dataRoot.path.hasPrefix(tempRoot.path)
              && PrivateStorage.classify(outside + "/x") == .outside,
              "config=\(configRoot.path) data=\(dataRoot.path)")

        // d2 — an existing 0700 skill helper rewritten by the agent stays 0700 and executes
        let helper = configRoot.appendingPathComponent("skills/x/helper.sh").path
        try plant(helper, script("v1"), 0o700)
        _ = await FilesystemTools.shared.readFile(path: helper)
        let w1 = await FilesystemTools.shared.writeFile(path: helper, content: script("v2"))
        check("9.1 d2 write_file over a 0700 skill helper succeeds", succeeded(w1), String(w1.content.prefix(200)))
        check("9.1a ...the helper is still 0700", mode(helper) == 0o700, octal(mode(helper)))
        check("9.1b ...and still executes with the new content", execute(helper) == "v2", execute(helper))
        _ = await FilesystemTools.shared.readFile(path: helper)
        let e1 = await FilesystemTools.shared.editFile(path: helper, oldString: "echo v2", newString: "echo v3")
        check("9.2 d2 edit_file on the 0700 helper succeeds", succeeded(e1), String(e1.content.prefix(200)))
        check("9.2a ...still 0700", mode(helper) == 0o700, octal(mode(helper)))
        check("9.2b ...and still executes", execute(helper) == "v3", execute(helper))
        let wideNote = dataRoot.appendingPathComponent("documents/note.txt").path
        try plant(wideNote, "note v1\n", 0o644)
        _ = await FilesystemTools.shared.readFile(path: wideNote)
        let w2 = await FilesystemTools.shared.writeFile(path: wideNote, content: "note v2\n")
        check("9.3 d2 write_file over a 0644 data-root file succeeds", succeeded(w2), String(w2.content.prefix(200)))
        check("9.3a ...and it comes back 0600 (group/other stripped, not preserved)", mode(wideNote) == 0o600, octal(mode(wideNote)))
        _ = await FilesystemTools.shared.readFile(path: wideNote)
        let e2 = await FilesystemTools.shared.editFile(path: wideNote, oldString: "v2", newString: "v3")
        check("9.3b edit_file keeps it 0600", succeeded(e2) && mode(wideNote) == 0o600, octal(mode(wideNote)))
        let newInRoot = dataRoot.appendingPathComponent("documents/brand-new.txt").path
        let w3 = await FilesystemTools.shared.writeFile(path: newInRoot, content: "new\n")
        check("9.4 a new file created inside a root is 0600", succeeded(w3) && mode(newInRoot) == 0o600, octal(mode(newInRoot)))
        check("9.4a ...in a 0700 parent (ensureDirectory)", mode(dataRoot.appendingPathComponent("documents").path) == 0o700,
              octal(mode(dataRoot.appendingPathComponent("documents").path)))

        // d3 — symlink inside a root → regular file inside a root: write through, link stays a link
        let realHelper = dataRoot.appendingPathComponent("documents/real.sh").path
        try plant(realHelper, script("r1"), 0o700)
        let helperLink = configRoot.appendingPathComponent("skills/x/link.sh").path
        try link(helperLink, to: realHelper)
        _ = await FilesystemTools.shared.readFile(path: helperLink)
        let w4 = await FilesystemTools.shared.writeFile(path: helperLink, content: script("r2"))
        check("9.5 d3 write_file through an in-root symlink succeeds", succeeded(w4), String(w4.content.prefix(200)))
        check("9.5a ...the link is still a link", isLink(helperLink))
        check("9.5b ...the target carries the new content", contents(realHelper) == script("r2"))
        check("9.5c ...and a 0700 target stays 0700", mode(realHelper) == 0o700, octal(mode(realHelper)))
        _ = await FilesystemTools.shared.readFile(path: helperLink)
        let e3 = await FilesystemTools.shared.editFile(path: helperLink, oldString: "echo r2", newString: "echo r3")
        check("9.6 d3 edit_file through the symlink updates the target, keeps the link",
              succeeded(e3) && isLink(helperLink) && contents(realHelper) == script("r3") && mode(realHelper) == 0o700,
              "link=\(isLink(helperLink)) mode=\(octal(mode(realHelper)))")
        let plainTarget = dataRoot.appendingPathComponent("documents/plain.txt").path
        try plant(plainTarget, "plain v1\n", 0o644)
        let plainLink = configRoot.appendingPathComponent("skills/x/plain-link.txt").path
        try link(plainLink, to: plainTarget)
        _ = await FilesystemTools.shared.readFile(path: plainLink)
        let w5 = await FilesystemTools.shared.writeFile(path: plainLink, content: "plain v2\n")
        check("9.7 d3 a 0644 target written through a link becomes 0600, link kept",
              succeeded(w5) && isLink(plainLink) && mode(plainTarget) == 0o600 && contents(plainTarget) == "plain v2\n",
              "mode=\(octal(mode(plainTarget)))")
        let danglingLink = configRoot.appendingPathComponent("skills/x/dangling.txt").path
        let danglingTarget = dataRoot.appendingPathComponent("documents/missing.txt").path
        try link(danglingLink, to: danglingTarget)
        let w6 = await FilesystemTools.shared.writeFile(path: danglingLink, content: "never\n")
        check("9.8 d3 write through a dangling symlink is refused with a clear error",
              !succeeded(w6) && errorText(w6).contains("dangling symlink"), errorText(w6))
        check("9.8a ...no file was created and the link is untouched",
              !fm.fileExists(atPath: danglingTarget) && isLink(danglingLink))
        let cycA = configRoot.appendingPathComponent("skills/x/cycA").path
        let cycB = configRoot.appendingPathComponent("skills/x/cycB").path
        try link(cycA, to: cycB)
        try link(cycB, to: cycA)
        let w7 = await FilesystemTools.shared.writeFile(path: cycA, content: "never\n")
        check("9.9 d3 a symlink cycle is refused", !succeeded(w7) && errorText(w7).contains("cycle"), errorText(w7))
        check("9.9a ...both links untouched", isLink(cycA) && isLink(cycB))

        // d4 (i) — a link resolving to harness-owned state is refused, the state is untouched
        let conversation = dataRoot.appendingPathComponent("conversation.json").path
        try plant(conversation, "{}", 0o600)
        let evil = configRoot.appendingPathComponent("skills/evil").path
        try link(evil, to: conversation)
        _ = await FilesystemTools.shared.readFile(path: evil)
        let w8 = await FilesystemTools.shared.writeFile(path: evil, content: "[]")
        check("9.10 d4(i) write_file through a link to conversation.json is refused",
              !succeeded(w8) && errorText(w8).contains("harness-owned state"), errorText(w8))
        check("9.10a ...conversation.json is byte-identical and 0600, link untouched",
              contents(conversation) == "{}" && mode(conversation) == 0o600 && isLink(evil),
              "content=\(contents(conversation)) mode=\(octal(mode(conversation)))")
        _ = await FilesystemTools.shared.readFile(path: evil)
        let e4 = await FilesystemTools.shared.editFile(path: evil, oldString: "{}", newString: "{ }")
        check("9.10b edit_file through that link is refused too, state untouched",
              !succeeded(e4) && contents(conversation) == "{}", errorText(e4))
        // d4 (ii) — user-authored in-scope link: written through, stripped
        let otherTarget = dataRoot.appendingPathComponent("documents/other.sh").path
        try plant(otherTarget, script("o1"), 0o755)
        let helper2 = configRoot.appendingPathComponent("skills/x/helper2.sh").path
        try link(helper2, to: otherTarget)
        _ = await FilesystemTools.shared.readFile(path: helper2)
        let w9 = await FilesystemTools.shared.writeFile(path: helper2, content: script("o2"))
        check("9.11 d4(ii) an in-scope link is written through with group/other stripped (0755 → 0700)",
              succeeded(w9) && isLink(helper2) && mode(otherTarget) == 0o700 && execute(otherTarget) == "o2",
              "mode=\(octal(mode(otherTarget))) run=\(execute(otherTarget))")
        // d4 (iii) — external and projects/ targets keep their EXACT mode
        let sharedScript = external + "/shared.sh"
        try plant(sharedScript, script("s1"), 0o755)
        let helperExt = configRoot.appendingPathComponent("skills/helper.sh").path
        try link(helperExt, to: sharedScript)
        _ = await FilesystemTools.shared.readFile(path: helperExt)
        let w10 = await FilesystemTools.shared.writeFile(path: helperExt, content: script("s2"))
        check("9.12 d4(iii) write_file through skills/helper.sh → external 0755 script updates the content",
              succeeded(w10) && contents(sharedScript) == script("s2") && isLink(helperExt), String(w10.content.prefix(200)))
        check("9.12a ...and leaves the external script EXACTLY 0755", mode(sharedScript) == 0o755, octal(mode(sharedScript)))
        _ = await FilesystemTools.shared.readFile(path: helperExt)
        let e5 = await FilesystemTools.shared.editFile(path: helperExt, oldString: "echo s2", newString: "echo s3")
        check("9.12b edit_file through it: content updated, still exactly 0755, still runs",
              succeeded(e5) && mode(sharedScript) == 0o755 && execute(sharedScript) == "s3" && isLink(helperExt),
              "mode=\(octal(mode(sharedScript))) run=\(execute(sharedScript))")
        let projectScript = dataRoot.appendingPathComponent("projects/proj/run.sh").path
        try plant(projectScript, script("p1"), 0o755)
        let projLink = configRoot.appendingPathComponent("skills/proj-link.sh").path
        try link(projLink, to: projectScript)
        _ = await FilesystemTools.shared.readFile(path: projLink)
        let w11 = await FilesystemTools.shared.writeFile(path: projLink, content: script("p2"))
        check("9.13 d4(iii) a link into projects/ writes through and keeps the target exactly 0755",
              succeeded(w11) && contents(projectScript) == script("p2") && mode(projectScript) == 0o755 && isLink(projLink),
              "mode=\(octal(mode(projectScript)))")
        let projectFile = dataRoot.appendingPathComponent("projects/proj/notes.txt").path
        try plant(projectFile, "n1\n", 0o644)
        _ = await FilesystemTools.shared.readFile(path: projectFile)
        let e6 = await FilesystemTools.shared.editFile(path: projectFile, oldString: "n1", newString: "n2")
        check("9.13a a file directly inside projects/ keeps 0644 (excluded from the policy)",
              succeeded(e6) && mode(projectFile) == 0o644, octal(mode(projectFile)))

        // outside-root control — unchanged behaviour for the user's own files
        let userFile = outside + "/user.txt"
        try plant(userFile, "u1\n", 0o644)
        _ = await FilesystemTools.shared.readFile(path: userFile)
        let e7 = await FilesystemTools.shared.editFile(path: userFile, oldString: "u1", newString: "u2")
        check("9.14 outside the roots edit_file keeps a 0644 file at 0644", succeeded(e7) && mode(userFile) == 0o644, octal(mode(userFile)))
        let userScript = outside + "/run.sh"
        try plant(userScript, script("u1"), 0o755)
        _ = await FilesystemTools.shared.readFile(path: userScript)
        let w12 = await FilesystemTools.shared.writeFile(path: userScript, content: script("u2"))
        check("9.14a outside the roots write_file keeps a 0755 script at 0755 and running",
              succeeded(w12) && mode(userScript) == 0o755 && execute(userScript) == "u2", octal(mode(userScript)))
        let userTarget = outside + "/target.txt"
        try plant(userTarget, "t1\n", 0o644)
        let userLink = outside + "/link.txt"
        try link(userLink, to: userTarget)
        _ = await FilesystemTools.shared.readFile(path: userLink)
        let w13 = await FilesystemTools.shared.writeFile(path: userLink, content: "t2\n")
        check("9.15 outside the roots a symlink still writes through as before (link kept, target 0644)",
              succeeded(w13) && isLink(userLink) && contents(userTarget) == "t2\n" && mode(userTarget) == 0o644,
              "link=\(isLink(userLink)) mode=\(octal(mode(userTarget)))")

        // apply_patch — the same essentials through the patch path
        let patchHelper = configRoot.appendingPathComponent("skills/x/patch.sh").path
        try plant(patchHelper, script("q1"), 0o700)
        _ = await FilesystemTools.shared.readFile(path: patchHelper)
        let p1 = await ApplyPatch.run(patchText: """
        *** Begin Patch
        *** Update File: \(patchHelper)
        @@
        -echo q1
        +echo q2
        *** End Patch
        """)
        check("9.16 apply_patch update of a 0700 helper keeps 0700 and it executes",
              !p1.content.contains("\"error\"") && mode(patchHelper) == 0o700 && execute(patchHelper) == "q2",
              "mode=\(octal(mode(patchHelper))) \(p1.content.prefix(160))")
        let patchNote = dataRoot.appendingPathComponent("documents/patch.txt").path
        try plant(patchNote, "k1\n", 0o644)
        _ = await FilesystemTools.shared.readFile(path: patchNote)
        let p2 = await ApplyPatch.run(patchText: """
        *** Begin Patch
        *** Update File: \(patchNote)
        @@
        -k1
        +k2
        *** End Patch
        """)
        check("9.17 apply_patch update of a 0644 data-root file comes back 0600",
              !p2.content.contains("\"error\"") && mode(patchNote) == 0o600 && contents(patchNote) == "k2\n",
              "mode=\(octal(mode(patchNote)))")
        let addedInRoot = dataRoot.appendingPathComponent("documents/added.txt").path
        let addedOutside = outside + "/added.txt"
        let p3 = await ApplyPatch.run(patchText: """
        *** Begin Patch
        *** Add File: \(addedInRoot)
        +added
        *** Add File: \(addedOutside)
        +added
        *** End Patch
        """)
        // Control for the outside add: exactly what a plain atomic Data write produces here.
        let controlOutside = outside + "/control.txt"
        try Data("added\n".utf8).write(to: URL(fileURLWithPath: controlOutside), options: .atomic)
        check("9.18 apply_patch add inside a root creates the file 0600",
              !p3.content.contains("\"error\"") && mode(addedInRoot) == 0o600, "mode=\(octal(mode(addedInRoot))) \(p3.content.prefix(160))")
        check("9.18a ...while an add outside the roots gets the plain atomic-write mode (unchanged behaviour)",
              mode(addedOutside) == mode(controlOutside), "added=\(octal(mode(addedOutside))) control=\(octal(mode(controlOutside)))")
        let moveSrc = configRoot.appendingPathComponent("skills/x/mv-src.txt").path
        let moveDst = configRoot.appendingPathComponent("skills/x/mv-dst.txt").path
        try plant(moveSrc, "m1\n", 0o644)
        _ = await FilesystemTools.shared.readFile(path: moveSrc)
        let p4 = await ApplyPatch.run(patchText: """
        *** Begin Patch
        *** Update File: \(moveSrc)
        *** Move to: \(moveDst)
        @@
        -m1
        +m2
        *** End Patch
        """)
        check("9.19 apply_patch move inside a root: destination 0600, source gone",
              !p4.content.contains("\"error\"") && mode(moveDst) == 0o600 && contents(moveDst) == "m2\n" && !fm.fileExists(atPath: moveSrc),
              "dst=\(octal(mode(moveDst))) \(p4.content.prefix(160))")
        let patchTarget = dataRoot.appendingPathComponent("documents/ptarget.sh").path
        try plant(patchTarget, script("y1"), 0o700)
        let patchLink = configRoot.appendingPathComponent("skills/x/plink.sh").path
        try link(patchLink, to: patchTarget)
        _ = await FilesystemTools.shared.readFile(path: patchLink)
        let p5 = await ApplyPatch.run(patchText: """
        *** Begin Patch
        *** Update File: \(patchLink)
        @@
        -echo y1
        +echo y2
        *** End Patch
        """)
        check("9.20 apply_patch through an in-root symlink updates the 0700 target, keeps the link",
              !p5.content.contains("\"error\"") && isLink(patchLink) && mode(patchTarget) == 0o700 && execute(patchTarget) == "y2",
              "link=\(isLink(patchLink)) mode=\(octal(mode(patchTarget)))")
        let patchExtLink = configRoot.appendingPathComponent("skills/x/pext.sh").path
        let patchExtTarget = external + "/pext.sh"
        try plant(patchExtTarget, script("z1"), 0o755)
        try link(patchExtLink, to: patchExtTarget)
        _ = await FilesystemTools.shared.readFile(path: patchExtLink)
        let p6 = await ApplyPatch.run(patchText: """
        *** Begin Patch
        *** Update File: \(patchExtLink)
        @@
        -echo z1
        +echo z2
        *** End Patch
        """)
        check("9.21 apply_patch through a link to an external 0755 script leaves it exactly 0755",
              !p6.content.contains("\"error\"") && mode(patchExtTarget) == 0o755 && execute(patchExtTarget) == "z2",
              "mode=\(octal(mode(patchExtTarget)))")
        // rollback after a failed second op: the in-root file is restored with the policy mode
        let rbFile = dataRoot.appendingPathComponent("documents/rb.txt").path
        try plant(rbFile, "a\nb\n", 0o644)
        _ = await FilesystemTools.shared.readFile(path: rbFile)
        let blocker = dataRoot.appendingPathComponent("documents/blocker.txt").path
        try plant(blocker, "x", 0o600)
        var contentAtRollback = ""
        var modeAtRollback = -1
        ApplyPatch.testHookBeforeRollback = {
            contentAtRollback = contents(rbFile)
            modeAtRollback = mode(rbFile)
        }
        let p7 = await ApplyPatch.run(patchText: """
        *** Begin Patch
        *** Update File: \(rbFile)
        @@
        -a
        +A
        *** Add File: \(blocker)/child.txt
        +never written
        *** End Patch
        """)
        ApplyPatch.testHookBeforeRollback = nil
        check("9.22 a failed second op rolls back: op1 had landed (policy mode) before the rollback",
              p7.content.contains("Rolled back") && contentAtRollback == "A\nb\n" && modeAtRollback == 0o600,
              "at-rollback content=\(contentAtRollback.debugDescription) mode=\(octal(modeAtRollback)) \(p7.content.prefix(160))")
        check("9.22a ...the restored file has the pre-patch bytes and the policy mode 0600",
              contents(rbFile) == "a\nb\n" && mode(rbFile) == 0o600 && !fm.fileExists(atPath: blocker + "/child.txt"),
              "content=\(contents(rbFile).debugDescription) mode=\(octal(mode(rbFile)))")

        // mcp.json and mcp-routing.json are written 0600 by their owners
        let mcpConfig = MCPRegistry.configFileURL.path
        try plant(mcpConfig, "{\"mcpServers\":{}}", 0o644)
        try MCPRegistry.saveConfigsToDisk([])
        check("9.23 MCPRegistry.saveConfigsToDisk writes mcp.json 0600 (even over a 0644 file)",
              mode(mcpConfig) == 0o600 && contents(mcpConfig).contains("mcpServers"), octal(mode(mcpConfig)))
        let routingFile = MCPAgentRouting.routingURL().path
        try plant(routingFile, "{}", 0o644)
        try MCPAgentRouting.save(config: ["Explore": MCPAgentRouting.AgentRouting(always: [], deferred: [])])
        check("9.24 MCPAgentRouting.save writes mcp-routing.json 0600 (even over a 0644 file)",
              mode(routingFile) == 0o600 && contents(routingFile).contains("Explore"), octal(mode(routingFile)))

        // web-pipeline.log: 0600, previous.log dropped after 7 days, kept at 2
        let logsDir = dataRoot.appendingPathComponent("logs").path
        let webLog = logsDir + "/web-pipeline.log"
        let previousLog = logsDir + "/web-pipeline.previous.log"
        try? fm.removeItem(atPath: webLog)
        try plant(previousLog, "old\n", 0o644)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-8 * 86_400)], ofItemAtPath: previousLog)
        WebPipelineLog.shared.append("selftest line 1")
        WebPipelineLog.shared.flushForTesting()
        check("9.25 web-pipeline.log is created 0600 in a 0700 logs/ dir",
              mode(webLog) == 0o600 && mode(logsDir) == 0o700 && contents(webLog).contains("selftest line 1"),
              "log=\(octal(mode(webLog))) dir=\(octal(mode(logsDir)))")
        check("9.25a ...and an 8-day-old web-pipeline.previous.log was removed", !fm.fileExists(atPath: previousLog))
        try plant(previousLog, "recent\n", 0o600)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 86_400)], ofItemAtPath: previousLog)
        WebPipelineLog.shared.append("selftest line 2")
        WebPipelineLog.shared.flushForTesting()
        check("9.25b ...while a 2-day-old previous log is kept", fm.fileExists(atPath: previousLog) && contents(previousLog) == "recent\n")
        // the log seam is a symlink refusal too: a link at the log path is never appended through
        try fm.removeItem(atPath: webLog)
        let logDecoy = tempRoot.appendingPathComponent("decoy.log").path
        try plant(logDecoy, "", 0o644)
        try link(webLog, to: logDecoy)
        WebPipelineLog.shared.append("selftest line 3")
        WebPipelineLog.shared.flushForTesting()
        check("9.26 a symlink at the log path is refused (decoy untouched, link kept)",
              contents(logDecoy) == "" && isLink(webLog))
        try fm.removeItem(atPath: webLog)

        // 10. Project instructions: the whole AGENTS.md chain from the repo
        //     root down to the touched path, root first, never above .git.
        let outer = tempRoot.appendingPathComponent("outer")
        let repo = outer.appendingPathComponent("repo")
        let app = repo.appendingPathComponent("app")
        let deep = app.appendingPathComponent("src/deep")
        try fm.createDirectory(at: deep, withIntermediateDirectories: true)
        try fm.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "OUTER-RULE\n".write(to: outer.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        try "ROOT-RULE\n".write(to: repo.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        try "APP-RULE\n".write(to: app.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        try "x\n".write(to: deep.appendingPathComponent("f.swift"), atomically: true, encoding: .utf8)
        let chain = ProjectInstructionsTracker.instructionFiles(
            forTouchedPath: deep.appendingPathComponent("f.swift").path).map { $0.standardizedFileURL.path }
        check("10.1 chain is repo root then nested file, root first, nothing above .git",
              chain == [repo.appendingPathComponent("AGENTS.md").standardizedFileURL.path,
                        app.appendingPathComponent("CLAUDE.md").standardizedFileURL.path], "\(chain)")
        let tracker = ProjectInstructionsTracker()
        let args = #"{"path":""# + deep.appendingPathComponent("f.swift").path + #""}"#
        let first = tracker.payload(toolName: "read_file", argumentsJSON: args) ?? ""
        let rootAt = first.range(of: "ROOT-RULE")?.lowerBound
        let appAt = first.range(of: "APP-RULE")?.lowerBound
        check("10.2 first touch injects both files, root before nested",
              rootAt != nil && appAt != nil && rootAt! < appAt! && !first.contains("OUTER-RULE"), first)
        check("10.3 second touch injects nothing new",
              tracker.payload(toolName: "read_file", argumentsJSON: args) == nil)
        tracker.clearLoaded(instructionFilePath: repo.appendingPathComponent("AGENTS.md").standardizedFileURL.path)
        let reload = tracker.payload(toolName: "read_file", argumentsJSON: args) ?? ""
        check("10.4 a pruned root file re-injects alone on the next nested touch",
              reload.contains("ROOT-RULE") && !reload.contains("APP-RULE"), reload)
        let rootOnly = ProjectInstructionsTracker.instructionFiles(
            forTouchedPath: repo.appendingPathComponent("README.md").path).map { $0.standardizedFileURL.path }
        check("10.5 a root-level touch loads only the root file",
              rootOnly == [repo.appendingPathComponent("AGENTS.md").standardizedFileURL.path], "\(rootOnly)")

        print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
        if failures > 0 { throw ExitCode(1) }
    }
}
