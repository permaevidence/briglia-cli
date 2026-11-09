import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// §7 knowledge rules (D3), §14.10b F3 / R3-1 (patch-receipt half) /
/// §21 note 3, and D9 (the secret store through the settings writer).
extension CodexPatchSelftest {

    static func ledgerTests(_ t: CPTest) async {
        await FileTimeTracker.shared.resetGPTForTesting()
        do {
            let d = t.dir("k1"); let p = d + "/x.txt"
            t.write(p, "x\n")
            let r = await t.apply(t.wrap("*** Delete File: \(p)"))
            t.check("K.1 Delete without GPT evidence is refused (P26)", r.outcome.status == .refused && r.outcome.category == .knowledge
                    && r.text == "apply_patch verification failed: read \(p) before deleting it" && t.exists(p), r.text)
            await FileTimeTracker.shared.recordRead(path: p)
            let r2 = await t.apply(t.wrap("*** Delete File: \(p)"))
            t.check("K.2 a standard (legacy) record never unlocks a GPT Delete (F3, P46)", r2.outcome.status == .refused && t.exists(p), r2.text)
            await t.seed(p)
            // Same size, same second: a replacement must still be caught (inode/ctime/ns).
            t.write(p, "y\n")
            let r3 = await t.apply(t.wrap("*** Delete File: \(p)"))
            t.check("K.3 a same-size replacement after the read makes the record stale", r3.outcome.status == .refused && t.read(p) == "y\n", r3.text)
            await t.seed(p)
            let r4 = await t.apply(t.wrap("*** Delete File: \(p)"))
            t.check("K.4 a fresh GPT record allows the Delete", r4.outcome.status == .applied && !t.exists(p), r4.text)
            await CodexPatch.settleEvidence(r4)
            let gone = await FileTimeTracker.shared.gptRecord(forKey: PrivateStorage.canonical(p))
            t.check("K.5 a delivered Delete forgets the path's GPT record", gone == nil)
        }
        do {
            let d = t.dir("k6"); let p = d + "/a.txt"
            t.write(p, "old\n")
            let r = await t.apply(t.wrap("*** Add File: \(p)\n+new"))
            t.check("K.6 Add over an existing file without evidence is refused (D3, P25)", r.outcome.status == .refused
                    && r.text.contains("already exists — read it first, or use *** Update File") && t.read(p) == "old\n", r.text)
            await t.seed(p)
            let r2 = await t.apply(t.wrap("*** Add File: \(p)\n+new"))
            t.check("K.7 Add over a fresh file replaces it (scenario 011 with knowledge)", r2.outcome.status == .applied && t.read(p) == "new\n", r2.text)
            t.write(d + "/s.txt", "s\n")
            t.write(d + "/dest.txt", "dest\n")
            let r3 = await t.apply(t.wrap("*** Update File: \(d)/s.txt\n*** Move to: \(d)/dest.txt\n@@\n-s\n+t"))
            t.check("K.8 Move onto an existing destination without evidence is refused (D3)", r3.outcome.status == .refused && t.read(d + "/dest.txt") == "dest\n" && t.read(d + "/s.txt") == "s\n", r3.text)
        }
        do {
            let d = t.dir("k9"); let p = d + "/u.txt"
            t.write(p, "a\n")
            let r = await t.apply(t.wrap("*** Update File: \(p)\n@@\n-a\n+b"))
            t.check("K.9 Update needs no prior read", r.outcome.status == .applied, r.text)
            // The patch's own committed receipt earns .gptPatch evidence once delivered.
            await CodexPatch.settleEvidence(r)
            let rec = await FileTimeTracker.shared.gptRecord(forKey: PrivateStorage.canonical(p))
            t.check("K.10 a delivered patch publishes .gptPatch evidence from its receipt", rec?.source == .gptPatch)
            let r2 = await t.apply(t.wrap("*** Delete File: \(p)"))
            t.check("K.11 that evidence allows a later Delete without a read", r2.outcome.status == .applied, r2.text)
        }
        do {
            // P52: a replacement between commit and settlement earns nothing.
            let d = t.dir("k12"); let p = d + "/r.txt"
            t.write(p, "a\n")
            let r = await t.apply(t.wrap("*** Update File: \(p)\n@@\n-a\n+b"))
            t.write(p, "c\n")
            await CodexPatch.settleEvidence(r)
            let rec = await FileTimeTracker.shared.gptRecord(forKey: PrivateStorage.canonical(p))
            t.check("K.12 a replacement between commit and settlement earns no .gptPatch record (P52)", rec == nil)
            // §21 note 3: an older GPT record must not be refreshed by an unseen replacement.
            await t.seed(p)
            let before = await FileTimeTracker.shared.gptRecord(forKey: PrivateStorage.canonical(p))
            let r2 = await t.apply(t.wrap("*** Update File: \(p)\n@@\n-c\n+d"))
            t.write(p, "e\n")
            await CodexPatch.settleEvidence(r2)
            let after = await FileTimeTracker.shared.gptRecord(forKey: PrivateStorage.canonical(p))
            t.check("K.13 an older GPT record is never refreshed from an unseen replacement (§21 note 3)",
                    after?.identity == before?.identity && after?.source == .gptReadFile)
        }
        do {
            // Standard evidence is untouched by GPT writes (F3, P20/P35).
            let d = t.dir("k14"); let p = d + "/std.txt"
            t.write(p, "a\n")
            await FileTimeTracker.shared.recordRead(path: p)
            let snapBefore = await FileTimeTracker.shared.standardSnapshotForTesting(path: p)
            let r = await t.apply(t.wrap("*** Update File: \(p)\n@@\n-a\n+bb"))
            await CodexPatch.settleEvidence(r)
            let snapAfter = await FileTimeTracker.shared.standardSnapshotForTesting(path: p)
            var standardStale = false
            do { try await FileTimeTracker.shared.assertFresh(path: p) } catch FileTimeError.stale { standardStale = true } catch {}
            t.check("K.14 a GPT write leaves the standard snapshot as it was (it goes stale, never refreshed)",
                    snapBefore != nil && snapAfter?.mtime == snapBefore?.mtime && snapAfter?.size == snapBefore?.size && standardStale)
            let q = d + "/never-read.txt"
            t.write(q, "q\n")
            let r2 = await t.apply(t.wrap("*** Update File: \(q)\n@@\n-q\n+r"))
            await CodexPatch.settleEvidence(r2)
            var notRead = false
            do { try await FileTimeTracker.shared.assertFresh(path: q) } catch FileTimeError.notRead { notRead = true } catch {}
            t.check("K.15 GPT evidence never unlocks the standard tools (P20)", notRead)
        }
        do {
            let d = t.dir("k16"); let p = d + "/s.txt"
            t.write(p, "one\n")
            await t.seed(p)
            t.write(p, "two\n")
            let r = await t.apply(t.wrap("*** Update File: \(p)\n@@\n-one\n+uno"))
            t.check("K.16 a context miss on a stale file adds 'changed since you last read it'",
                    r.outcome.category == .context && r.text.contains("note: \(p) changed since you last read it at "), r.text)
        }
        do {
            // §21 note 1: the identity is taken from the descriptor BEFORE the
            // bytes are read and compared after; an in-place write in between
            // (same inode) is caught, never credited.
            let d = t.dir("k17"); let p = d + "/inplace.txt"
            t.write(p, "a\n")
            await t.seed(p)
            CodexPatchFS.readObservedHook = { path in
                guard path.hasSuffix("/inplace.txt"), let h = FileHandle(forWritingAtPath: path) else { return }
                h.seekToEndOfFile(); h.write(Data("appended\n".utf8)); h.closeFile()
            }
            let r = await t.apply(t.wrap("*** Delete File: \(p)"))
            CodexPatchFS.readObservedHook = nil
            t.check("K.17 an in-place write during the pre-image read is caught (§21 note 1)",
                    r.outcome.status == .refused && t.read(p) == "a\nappended\n" && r.text.contains("changed while it was being read"), r.text)
        }
        await FileTimeTracker.shared.resetGPTForTesting()
    }

    // MARK: D9

    static func secretsDict() -> [String: String] {
        guard let data = FileManager.default.contents(atPath: KeychainHelper.secretStorePath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return obj
    }

    static func secretStoreTests(_ t: CPTest) async {
        let store = KeychainHelper.secretStorePath
        guard store.hasPrefix(ProcessInfo.processInfo.environment["HOME"] ?? "/nonexistent") else {
            t.check("S.0 the secret store is inside the scratch home", false, store); return
        }
        try? KeychainHelper.save(key: KeychainHelper.jinaApiKeyKey, value: "jina-old")
        try? KeychainHelper.save(key: KeychainHelper.serperApiKeyKey, value: "serper-old")
        try? KeychainHelper.save(key: KeychainHelper.telegramBotTokenKey, value: "123456789:AAsyntheticTokenForTheCodexPatchTest")
        let text = String(decoding: FileManager.default.contents(atPath: store) ?? Data(), as: UTF8.self)
        let jinaLine = text.components(separatedBy: "\n").first { $0.contains(KeychainHelper.jinaApiKeyKey) } ?? ""
        let tokenLine = text.components(separatedBy: "\n").first { $0.contains(KeychainHelper.telegramBotTokenKey) } ?? ""
        t.check("S.0 fixture: a pretty-printed store with the token, Jina and Serper keys", !jinaLine.isEmpty && !tokenLine.isEmpty, text)

        let newJina = jinaLine.replacingOccurrences(of: "jina-old", with: "jina-new")
        let r = await t.apply(t.wrap("*** Update File: \(store)\n@@\n-\(jinaLine)\n+\(newJina)"))
        t.check("S.1 a field Update goes through the settings writer (D9)", r.outcome.status == .applied && secretsDict()[KeychainHelper.jinaApiKeyKey] == "jina-new"
                && secretsDict()[KeychainHelper.telegramBotTokenKey] == "123456789:AAsyntheticTokenForTheCodexPatchTest", r.text)

        let r2 = await t.apply(t.wrap("*** Update File: \(store)\n@@\n-\(tokenLine)\n+  \"\(KeychainHelper.telegramBotTokenKey)\" : \"1:x\","))
        t.check("S.2 a hunk touching the token field is refused", r2.outcome.status == .refused && r2.outcome.category == .protected && r2.text.contains("Telegram bot token"), r2.text)

        let r3 = await t.apply(t.wrap("*** Add File: \(store)\n+{}"))
        let r4 = await t.apply(t.wrap("*** Delete File: \(store)"))
        let r5 = await t.apply(t.wrap("*** Update File: \(store)\n*** Move to: \(store).moved\n@@\n-\(newJina)\n+\(newJina)"))
        t.check("S.3 Add/Delete/Move of the secret store are refused with the existing texts (P27)",
                r3.text.contains(HarnessSecretStore.wholeFileRewriteRefusal) && r4.text.contains(HarnessSecretStore.deleteOrMoveRefusal)
                && r5.text.contains(HarnessSecretStore.deleteOrMoveRefusal) && FileManager.default.fileExists(atPath: store)
                && !FileManager.default.fileExists(atPath: store + ".moved"), [r3, r4, r5].map(\.text).joined(separator: " | "))

        // Rollback by inverse delta: a later failure undoes the store edit;
        // an unrelated concurrent settings change survives commit and rollback.
        let d = t.dir("s6")
        let cur = String(decoding: FileManager.default.contents(atPath: store) ?? Data(), as: UTF8.self)
        let jina2 = cur.components(separatedBy: "\n").first { $0.contains(KeychainHelper.jinaApiKeyKey) } ?? ""
        let jina3 = jina2.replacingOccurrences(of: "jina-new", with: "jina-third")
        try? KeychainHelper.save(key: KeychainHelper.userContextKey, value: "concurrent maintenance write")
        t.write(d + "/late.txt", "late\n")
        await t.seed(d + "/late.txt")
        // The Delete runs after the store Update (order: adds, updates, moves, deletes).
        CodexPatchTransaction.faultInjector = { point, path in point == .remove && path.hasSuffix("/late.txt") }
        let r6 = await t.apply(t.wrap("*** Update File: \(store)\n@@\n-\(jina2)\n+\(jina3)\n*** Delete File: \(d)/late.txt"))
        CodexPatchTransaction.faultInjector = nil
        t.check("S.4 a later failure rolls the store back through the inverse delta; the unrelated change survives",
                r6.outcome.status == .rolledBack && secretsDict()[KeychainHelper.jinaApiKeyKey] == "jina-new"
                && secretsDict()[KeychainHelper.userContextKey] == "concurrent maintenance write" && r6.outcome.restored.contains(store), r6.text)

        // Overlapping change between the patch's read and its commit: refused.
        let cur2 = String(decoding: FileManager.default.contents(atPath: store) ?? Data(), as: UTF8.self)
        let serperLine = cur2.components(separatedBy: "\n").first { $0.contains(KeychainHelper.serperApiKeyKey) } ?? ""
        CodexPatchTransaction.faultInjector = nil
        // Change the key right before the commit (after preflight) through the hook.
        let changeOnce = OnceFlag()
        CodexPatchTransaction.beforeRevalidateHook = { _ in }
        let task = Task { () -> CodexPatch.Result in
            await CodexPatch.apply(.init(input: t.wrap("*** Update File: \(store)\n@@\n-\(serperLine)\n+\(serperLine.replacingOccurrences(of: "serper-old", with: "serper-agent"))"),
                                         isCancelled: { if changeOnce.take() { try? KeychainHelper.save(key: KeychainHelper.serperApiKeyKey, value: "serper-menu") }; return false }))
        }
        let r7 = await task.value
        CodexPatchTransaction.beforeRevalidateHook = nil
        t.check("S.5 an overlapping settings change after preflight is refused, nothing written",
                r7.outcome.status != .applied && secretsDict()[KeychainHelper.serperApiKeyKey] == "serper-menu" && r7.text.contains("changed since you read it"), r7.text)
        try? KeychainHelper.delete(key: KeychainHelper.telegramBotTokenKey)
    }

    final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false
        func take() -> Bool { lock.lock(); defer { lock.unlock() }; if used { return false }; used = true; return true }
    }
}
