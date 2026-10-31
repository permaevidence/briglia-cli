import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Codex live-menu implementation review, round 3: the invalidation
/// tombstone is read strictly, a write whose invalidation can be recorded
/// nowhere is refused before it happens, and the inline terminal/app
/// command reports a saved-but-uncancelled write.
extension LiveMenuHarness {
    func round3Section() async {
        await r5UnsearchableConfigRootSection()
        await r4UnsearchableDataRootSection()
        await r3UnreadableTombstoneSection()
        await r3NoPersistenceRefusesSection()
        await r3InlineNoteSection()
    }

    func stageModel(_ writer: SettingsWriter, _ owner: FakeSettingsOwner, _ value: String) async -> PreparedChange? {
        owner.busy = true
        defer { owner.busy = false }
        guard let c = await prepare(label: "AI model", { try KeychainHelper.save(key: KeychainHelper.openRouterModelKey, value: value) }) else { return nil }
        let r = await writer.commit(c)
        return r.state == .pending ? c : nil
    }

    // MARK: R3-1

    func r3UnreadableTombstoneSection() async {
        for variant in ["unreadable", "malformed"] {
            reset(Self.routeBase)
            defer {
                chmod(SettingsSupersede.tombstoneURL.path, 0o600)
                SettingsSupersede.discardInvalidations()
            }
            let owner = FakeSettingsOwner()
            let writer = SettingsWriter(host: owner)
            guard let c = await stageModel(writer, owner, "stale/model") else { check("R3-1: \(variant): fixture", false); continue }
            try? PrivateStorage.ensureDirectory(StoragePaths.dataRoot)
            if variant == "unreadable" {
                try? JSONEncoder().encode([c.id]).write(to: SettingsSupersede.tombstoneURL)
                chmod(SettingsSupersede.tombstoneURL.path, 0o000)
            } else {
                try? Data("{ not json".utf8).write(to: SettingsSupersede.tombstoneURL)
            }
            SettingsSupersede._testForgetInMemory()
            let applied = await writer.applyStaged(category: "ai")
            check("R3-1: an \(variant) tombstone is unknown evidence: the staged change is not applied and the file is kept",
                  applied == nil && store()[KeychainHelper.openRouterModelKey] != "stale/model"
                  && FileManager.default.fileExists(atPath: SettingsSupersede.tombstoneURL.path),
                  "applied \(String(describing: applied?.state))")
            guard let other = await prepare(label: "Serper key", { try KeychainHelper.save(key: KeychainHelper.serperApiKeyKey, value: "serper-r3") }) else { continue }
            let r = await writer.commit(other)
            check("R3-1: an \(variant) tombstone refuses further commits (fail closed)",
                  r.state == .refused && store()[KeychainHelper.serperApiKeyKey] != "serper-r3", "\(r.state)")
        }
    }

    // MARK: R5-1

    /// Codex round 5: an unsearchable CONFIG folder (pending file unknown)
    /// must not make a flush delete the tombstone; once readable again the
    /// staged change is dropped, never applied.
    func r5UnsearchableConfigRootSection() async {
        reset(Self.routeBase)
        let configRoot = StoragePaths.configRoot
        defer {
            chmod(configRoot.path, 0o700)
            SettingsSupersede.discardInvalidations()
        }
        let owner = FakeSettingsOwner()
        let writer = SettingsWriter(host: owner)
        guard let c = await stageModel(writer, owner, "stale/model") else { check("R5-1: fixture", false); return }
        let before = store()[KeychainHelper.openRouterModelKey]
        try? PrivateStorage.ensureDirectory(StoragePaths.dataRoot)
        try? JSONEncoder().encode([c.id]).write(to: SettingsSupersede.tombstoneURL)
        guard let other = await prepare(label: "Serper key", { try KeychainHelper.save(key: KeychainHelper.serperApiKeyKey, value: "serper-r5") }) else { return }
        SettingsSupersede._testForgetInMemory()
        chmod(configRoot.path, 0o600)
        var presenceThrows = false
        do { _ = try SettingsPendingStore.presence() } catch { presenceThrows = true }
        let r = await writer.commit(other)
        let kept = FileManager.default.fileExists(atPath: SettingsSupersede.tombstoneURL.path)
        chmod(configRoot.path, 0o700)
        check("R5-1: with the pending file unknown, a commit refuses and the tombstone is kept",
              presenceThrows && r.state == .refused && kept, "presence \(presenceThrows) \(r.state) kept \(kept)")
        let applied = await writer.applyStaged(category: "ai")
        check("R5-1: once readable, the tombstoned change is dropped, never applied",
              applied == nil && store()[KeychainHelper.openRouterModelKey] == before
              && pendingDoc().lastResults.contains { $0.clientRequestId == c.id && $0.state == "dropped" },
              "applied \(String(describing: applied?.state))")
    }

    // MARK: R4-1

    /// Codex round 4: an existing tombstone behind an unsearchable data
    /// folder is unknown evidence, not absence.
    func r4UnsearchableDataRootSection() async {
        reset(Self.routeBase)
        let dataRoot = StoragePaths.dataRoot
        defer {
            chmod(dataRoot.path, 0o700)
            SettingsSupersede.discardInvalidations()
        }
        let owner = FakeSettingsOwner()
        let writer = SettingsWriter(host: owner)
        guard let c = await stageModel(writer, owner, "stale/model") else { check("R4-1: fixture", false); return }
        let before = store()[KeychainHelper.openRouterModelKey]
        try? PrivateStorage.ensureDirectory(dataRoot)
        try? JSONEncoder().encode([c.id]).write(to: SettingsSupersede.tombstoneURL)
        SettingsSupersede._testForgetInMemory()
        chmod(dataRoot.path, 0o600)
        var strictThrows = false
        do { _ = try SettingsSupersede.readTombstonesStrict() } catch { strictThrows = true }
        let applied = await writer.applyStaged(category: "ai")
        let stillStaged = pendingDoc().slots["ai"]?.staged?.change.id == c.id
        chmod(dataRoot.path, 0o700)
        check("R4-1: a tombstone behind an unsearchable data folder is unknown: nothing applied, the change stays staged, the file is kept",
              strictThrows && applied == nil && stillStaged && store()[KeychainHelper.openRouterModelKey] == before
              && SettingsSupersede.tombstonedIds().contains(c.id),
              "strict \(strictThrows) applied \(String(describing: applied?.state)) staged \(stillStaged)")
    }

    // MARK: R3-2

    func r3NoPersistenceRefusesSection() async {
        reset(Self.routeBase)
        SettingsSupersede.install()
        let dataRoot = StoragePaths.dataRoot
        try? PrivateStorage.ensureDirectory(dataRoot)
        defer {
            chmod(dataRoot.path, 0o700)
            SettingsPendingStore.failWritesForTesting = false
            SettingsSupersede.discardInvalidations()
            SettingsSupersede.uninstall()
        }
        let owner = FakeSettingsOwner()
        let writer = SettingsWriter(host: owner)
        guard let staged = await stageModel(writer, owner, "stale/model") else { check("R3-2: fixture", false); return }
        let before = store()[KeychainHelper.openRouterModelKey]
        SettingsPendingStore.failWritesForTesting = true
        chmod(dataRoot.path, 0o500)
        guard let toB = await prepare(label: "agent", { try KeychainHelper.save(key: KeychainHelper.openRouterModelKey, value: "b/model") }) else { return }
        let r = await writer.commit(toB, policy: .immediate)
        check("R3-2: a write whose invalidation can be recorded nowhere is refused before it happens",
              r.state != .applied && store()[KeychainHelper.openRouterModelKey] == before, "\(r.state) \(r.message ?? "")")
        // A direct write (a Telegram command body) is refused the same way.
        var directError: Error?
        do { try KeychainHelper.save(key: KeychainHelper.openRouterModelKey, value: "direct/model") } catch { directError = error }
        check("R3-2: a direct secrets write that would supersede it is refused too",
              directError is SettingsSupersede.InvalidationNotRecorded && store()[KeychainHelper.openRouterModelKey] == before)
        // Ordinary turnover: nothing was lost — the staged change is still
        // the only change, and it applies once the files are writable.
        chmod(dataRoot.path, 0o700)
        SettingsPendingStore.failWritesForTesting = false
        SettingsSupersede._testForgetInMemory()
        let applied = await writer.applyStaged(category: "ai")
        check("R3-2: with nothing written, the staged change is still valid and applies (no stale revival possible)",
              applied?.state == .applied && store()[KeychainHelper.openRouterModelKey] == "stale/model"
              && pendingDoc().lastResults.contains { $0.clientRequestId == staged.id && $0.state == "applied" })
    }

    // MARK: inline note

    func r3InlineNoteSection() async {
        reset(Self.routeBase.merging([KeychainHelper.keylessSearchKey: "true"]) { $1 })
        ConversationManager.settingsRetrySecondsForTesting = 600
        let manager = ConversationManager()
        manager.startSettingsOwner()
        defer {
            ConversationManager.settingsRetrySecondsForTesting = 10
            SettingsPendingStore.failWritesForTesting = false
            SettingsSupersede.discardInvalidations()
            SettingsClient.inProcessOwner = nil
            SettingsAgentEdit.immediateOwner = nil
            SettingsSupersede.uninstall()
            ProcessKind.isDaemon = false
        }
        manager._testSetActiveProcessing(true)
        guard let staged = await prepare(label: "Free search", { try KeychainHelper.save(key: KeychainHelper.keylessSearchKey, value: "false") }) else { return }
        _ = await SettingsClient.commit(staged)
        manager._testSetActiveProcessing(false)
        SettingsPendingStore.failWritesForTesting = true
        let replies = await manager.handleTerminalCommand("/freesearch off") ?? []
        check("R3 note: an inline terminal/app command reports a saved write whose invalidation is unsaved",
              store()[KeychainHelper.keylessSearchKey] == "false" && replies.contains { $0.contains("could not be cancelled") },
              "\(replies.suffix(2))")
    }
}
