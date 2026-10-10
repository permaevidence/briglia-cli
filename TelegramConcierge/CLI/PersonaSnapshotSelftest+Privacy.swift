import Foundation

/// P6, P6b, P6c, P7: the snapshot is memory-only. After /deleteuserdata no
/// request carries the deleted profile (a queued retry included); a
/// restarted turn captures fresh; no persisted checkpoint, session or Mind
/// export carries a persona snapshot field or the snapshot's text.
extension MidturnHarness {

    /// Field names a persisted snapshot would leave behind.
    static let ppSnapshotFieldNames = ["PromptPersona", "previousName", "turnPersona", "runPersona"]

    /// Every regular file below `root` whose bytes contain one of `needles`.
    static func ppFilesContaining(_ needles: [String], under root: URL, skipping: Set<String> = []) -> [String] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var hits: [String] = []
        for case let url as URL in walker where !skipping.contains(url.lastPathComponent) {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let data = try? Data(contentsOf: url) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            if needles.contains(where: { text.contains($0) }) { hits.append(url.path.replacingOccurrences(of: root.path, with: "")) }
        }
        return hits
    }

    /// Conversation, checkpoint and session state (not the profile store,
    /// archives of earlier rows, logs or the retired-facts file).
    func ppPersistedStateFiles(_ manager: ConversationManager) -> [URL] {
        let root = StoragePaths.dataRoot
        var urls = [root.appendingPathComponent("conversation.json"), manager._testSalvageURL, manager._testActiveTurnMarkerURL,
                    root.appendingPathComponent("pending_midturn.json")]
        let sessions = root.appendingPathComponent("subagent_sessions")
        urls += ((try? FileManager.default.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil)) ?? [])
        return urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func ppScan(_ urls: [URL], for needles: [String]) -> [String] {
        urls.filter { url in
            let text = String(decoding: (try? Data(contentsOf: url)) ?? Data(), as: UTF8.self)
            return needles.contains { text.contains($0) }
        }.map(\.lastPathComponent)
    }

    func ppPrivacySection() async throws {
        // P6: /deleteuserdata. Afterwards no request (main, any subagent)
        // contains the deleted profile; the deleted session stays unavailable.
        do {
            let tag = "P6"
            let a = Self.ppSentinel("A")
            let (manager, router, capture, done) = try await ppStart()
            try ppSetProfile(Self.ppProfile(a))
            router.push([(id: "\(tag)-1", name: "bash", args: ["command": "echo one"])])
            router.pushText("before deletion")
            await ppTurn(manager, "\(tag) before deletion")
            router.pushText("subagent answer")
            let runner = SubagentRunner()
            let service = OpenRouterService(); await service.configure(apiKey: apiKey)
            let executor = ToolExecutor(outputMode: .subagent)
            let images = StoragePaths.dataRoot.appendingPathComponent("images")
            func subagent(_ session: String?) async -> SubagentRunner.RunResult {
                await runner.run(invocation: SubagentRunner.Invocation(subagentType: "general-purpose", description: "Persona fixture",
                    taskPrompt: "\(tag) subagent task", modelOverride: nil, runInBackground: false),
                    sessionId: session, openRouterService: service, toolExecutor: executor,
                    imagesDirectory: images, documentsDirectory: images, parentTools: [AvailableTools.readFile])
            }
            let before = await subagent(nil)
            let sawBefore = capture.requests.contains { Self.ppText($0.body).contains(a) }
            let failures = await manager.deleteAllMemory()
            check("\(tag)0 setup: the profile was on the wire, the wipe succeeded", sawBefore && failures.isEmpty, failures.joined(separator: "; "))
            let mark = capture.mark()
            let serverMark = server.completeRequests.count
            router.pushText("after deletion")
            await ppTurn(manager, "\(tag) after deletion")
            router.pushText("fresh subagent answer")
            _ = await subagent(nil)
            router.pushText("resume attempt answer")
            let resumed = await subagent(before.sessionId)
            let after = server.completeRequests.dropFirst(serverMark).map { Self.ppText($0.body) }
            check("\(tag)a after the wipe no request (main turn, fresh subagent, resume attempt) carries the deleted profile",
                  !after.isEmpty && capture.main(since: mark.requests).count >= 1 && after.allSatisfy { !$0.contains(a) },
                  "requests \(after.count), with sentinel \(after.filter { $0.contains(a) }.count)")
            check("\(tag)s the deleted session is not resumed with its old history",
                  resumed.error != nil || resumed.isNewSession || resumed.sessionId != before.sessionId,
                  "error \(resumed.error ?? "-") new \(resumed.isNewSession)")
            done()
        }
        try await ppQueuedRetrySection()
    }

    /// P6b: a retry waiting in its backoff when the turn is stopped and the
    /// data deleted never sends the deleted profile.
    func ppQueuedRetrySection() async throws {
        let tag = "P6b"
        let a = Self.ppSentinel("A")
        let (manager, router, capture, done) = try await ppStart()
        defer { OpenRouterService.chatRetryTestHooks = OpenRouterService.ChatRetryTestHooks() }
        try ppSetProfile(Self.ppProfile(a))
        router.pushText("never sent")
        let first = PPBox(true)
        server.routedStatus = { _ in
            guard first.value else { return nil }
            first.value = false
            return 503
        }
        let retryQueued = PPBox(false)
        OpenRouterService.chatRetryTestHooks.sleepScale = 4
        OpenRouterService.chatRetryTestHooks.retrySink = { _, _, _ in retryQueued.value = true }
        manager._testStartTurn(for: user("\(tag) turn"))
        let queued = await waitUntil(timeout: 20) { retryQueued.value }
        await manager._testStop()
        _ = await manager._testAwaitIdle(timeout: 30)
        let stopMark = server.completeRequests.count
        let failures = await manager.deleteAllMemory()
        try? await Task.sleep(nanoseconds: 9_000_000_000)   // past every scaled backoff
        let later = server.completeRequests.dropFirst(stopMark).map { Self.ppText($0.body) }
        check("\(tag) a retry queued in its backoff, then /stop and the wipe: it never sends the deleted profile",
              queued && failures.isEmpty && later.allSatisfy { !$0.contains(a) },
              "queued \(queued), wipe \(failures), later requests \(later.count), carrying it \(later.filter { $0.contains(a) }.count)")
        _ = capture
        server.routedStatus = nil
        done()
    }

    /// P6c: a turn interrupted by a crash after a mid-turn profile change;
    /// the recovered turn captures the post-restart profile. Neither the
    /// crash files nor the later state carry a snapshot field or text.
    func ppRestartSection() async throws {
        let tag = "P6c"
        let a = Self.ppSentinel("A"), b = Self.ppSentinel("B")
        let (manager, router, capture, done) = try await ppStart()
        try ppSetProfile(Self.ppProfile(a))
        let stash = StoragePaths.dataRoot.appendingPathComponent("pp-stash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stash, withIntermediateDirectories: true)
        let crashFiles = [StoragePaths.dataRoot.appendingPathComponent("conversation.json"), manager._testSalvageURL, manager._testActiveTurnMarkerURL]
        let captured = PPBox(false)
        router.onMain = { n, _ in
            if n == 1 { try? KeychainHelper.save(key: KeychainHelper.structuredUserContextKey, value: Self.ppProfile(b)) }
            if n == 3 {
                for file in crashFiles where FileManager.default.fileExists(atPath: file.path) {
                    try? FileManager.default.copyItem(at: file, to: stash.appendingPathComponent(file.lastPathComponent))
                }
                captured.value = FileManager.default.fileExists(atPath: stash.appendingPathComponent(crashFiles[2].lastPathComponent).path)
            }
        }
        router.push([(id: "\(tag)-1", name: "bash", args: ["command": "echo one"])])
        router.push([(id: "\(tag)-2", name: "bash", args: ["command": "echo two"])])
        router.pushText("finished before the crash copy is restored")
        let mark = capture.mark()
        await ppTurn(manager, "\(tag) turn interrupted by a crash")
        router.onMain = nil
        check("\(tag)0 the crash point was captured mid-turn, after the profile change", captured.value)
        ppAssertTurnFrozen(tag, capture, since: mark, old: a, new: b, minRequests: 3)
        let stashed = (try? FileManager.default.contentsOfDirectory(at: stash, includingPropertiesForKeys: nil)) ?? []
        check("\(tag)d the crash-time checkpoint files carry no snapshot field and no profile text",
              !stashed.isEmpty && ppScan(stashed, for: Self.ppSnapshotFieldNames + [a, b]).isEmpty,
              "\(ppScan(stashed, for: Self.ppSnapshotFieldNames + [a, b]))")
        for file in crashFiles {
            try? FileManager.default.removeItem(at: file)
            let saved = stash.appendingPathComponent(file.lastPathComponent)
            if FileManager.default.fileExists(atPath: saved.path) { try? FileManager.default.copyItem(at: saved, to: file) }
        }
        try? FileManager.default.removeItem(at: stash)
        let restarted = await restart()
        router.pushText("recovered turn done")
        let next = capture.mark()
        restarted._testStartupPasses()
        _ = await restarted._testAwaitIdle(timeout: 60)
        let recovered = capture.main(since: next.requests)
        check("\(tag)e the recovered turn captures the post-restart profile",
              !recovered.isEmpty && recovered.allSatisfy { Self.ppSystem($0).contains(b) && !Self.ppText($0).contains(a) },
              "requests \(recovered.count)")
        let state = ppPersistedStateFiles(restarted)
        check("\(tag)f persisted conversation, checkpoint and session files carry no snapshot field or profile text",
              !state.isEmpty && ppScan(state, for: Self.ppSnapshotFieldNames + [a, b]).isEmpty, "\(ppScan(state, for: Self.ppSnapshotFieldNames + [a, b]))")
        done()
        try await ppEnvelopeCheckpointSection()
    }

    /// P6c (envelope): after an active-turn compaction the whole turn
    /// checkpoint (TurnCheckpoint) is what is persisted; captured right
    /// after the compaction, it carries no snapshot field or profile text.
    func ppEnvelopeCheckpointSection() async throws {
        let tag = "P6c-envelope"
        let restoreSettings = try ppLongTurnSettings(mainRounds: nil)
        defer { restoreSettings() }
        let large = try ppLargeFile()
        let a = Self.ppSentinel("A"), b = Self.ppSentinel("B")
        let (manager, router, _, done) = try await ppStart()
        try ppSetProfile(Self.ppProfile(a))
        let salvage = manager._testSalvageURL
        let copy = PPBox<Data?>(nil)
        router.onMain = { [router] n, _ in
            if n == 1 { try? KeychainHelper.save(key: KeychainHelper.structuredUserContextKey, value: Self.ppProfile(b)) }
            if copy.value == nil, router.compactions > 0 { copy.value = try? Data(contentsOf: salvage) }
        }
        router.readUntilCompaction = large
        router.pushText("compacted turn done")
        await ppTurn(manager, "\(tag) read the file many times", timeout: 300)
        router.onMain = nil; router.readUntilCompaction = nil
        let text = copy.value.map { String(decoding: $0, as: UTF8.self) } ?? ""
        check("\(tag) the envelope checkpoint written after a compaction carries no snapshot field or profile text",
              router.compactions >= 1 && text.contains("activeTurnCompaction")
                && !(Self.ppSnapshotFieldNames + [a, b]).contains { text.contains($0) },
              "compactions \(router.compactions), checkpoint bytes \(text.utf8.count)")
        done()
    }

    /// P7: Mind export carries the profile (as today), never a snapshot;
    /// after an import the next turn uses the imported profile.
    func ppMindSection() async throws {
        let tag = "P7"
        let a = Self.ppSentinel("A"), m = Self.ppSentinel("M"), z = Self.ppSentinel("Z")
        let (manager, router, capture, done) = try await ppStart()
        let channel = SVRecordingChannel(kind: .telegram)
        manager._svRegisterChannel(channel)
        manager._svSetLastUserAddress(ChannelAddress(kind: .telegram, chatId: "1234567"))
        try ppSetProfile(Self.ppProfile(a))
        // A turn whose snapshot (A) differs from the store (M) when exported.
        router.onMain = { n, _ in
            if n == 1 { try? KeychainHelper.save(key: KeychainHelper.structuredUserContextKey, value: Self.ppProfile(m)) }
        }
        router.push([(id: "\(tag)-1", name: "bash", args: ["command": "echo one"])])
        router.pushText("turn before export")
        await ppTurn(manager, "\(tag) turn before export")
        router.onMain = nil
        let export = StoragePaths.dataRoot.deletingLastPathComponent().appendingPathComponent("pp-\(UUID().uuidString).mind")
        try await MindExportService.shared.exportMind(to: export)
        defer { try? FileManager.default.removeItem(at: export) }
        let unzip = ["/usr/bin/unzip", "/bin/unzip"].first { FileManager.default.isExecutableFile(atPath: $0) }
        if let unzip {
            let out = StoragePaths.dataRoot.deletingLastPathComponent().appendingPathComponent("pp-unzip-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: out) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: unzip)
            process.arguments = ["-q", "-o", export.path, "-d", out.path]
            try process.run(); process.waitUntilExit()
            let fieldHits = Self.ppFilesContaining(Self.ppSnapshotFieldNames, under: out)
            let snapshotHits = Self.ppFilesContaining([a], under: out)
            let profileHits = Self.ppFilesContaining([m], under: out)
            check("\(tag)a the export carries no snapshot field and not the turn's snapshot text; the profile only as the store holds it",
                  process.terminationStatus == 0 && fieldHits.isEmpty && snapshotHits.isEmpty && profileHits.allSatisfy { $0.hasSuffix("mind_config.json") } && !profileHits.isEmpty,
                  "fields \(fieldHits), snapshot \(snapshotHits), profile \(profileHits)")
        } else {
            print("⚠ SKIP: unzip not installed — export content scan skipped")
        }
        try ppSetProfile(Self.ppProfile(z))
        router.pushText("turn with Z")
        await ppTurn(manager, "\(tag) turn with Z")
        let staged = await manager.handleTerminalCommand("/importmind \(export.path)") ?? []
        let confirmed = await manager.handleTerminalCommand("/importmind confirm") ?? []
        let imported = (confirmed + channel.delivered).contains { $0.hasPrefix("✅ Memory restored") }
        router.pushText("turn after import")
        let next = capture.mark()
        await ppTurn(manager, "\(tag) turn after import")
        let first = capture.main(since: next.requests).first.map(Self.ppSystem) ?? ""
        check("\(tag)b after /importmind the next turn uses the imported profile",
              imported && first.contains(m) && !first.contains(z), "imported \(imported): \(staged.joined().prefix(300)) | \(confirmed.joined().prefix(300))")
        done()
    }
}
