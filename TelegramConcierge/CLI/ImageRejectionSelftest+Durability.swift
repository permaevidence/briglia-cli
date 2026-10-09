import Foundation

struct IRInjected: Error {}

/// Persistence rows (plan v2 §2.5 R3, R4, R12, P5 and the Codex round-2
/// extensions): failed writes never resend; a crash at each save boundary
/// either repeats one free 400 or keeps the exclusion — never loses a
/// durable one; marks travel through prune snapshots and Mind transfer.
extension MidturnHarness {

    func irDurabilitySection() async throws {
        try await irWriteFailures()
        try await irBoundaryRestart(responses: false)
        let restore = try useResponses()
        do { try await irBoundaryRestart(responses: true) }
        restore()
        try await irUserImageBoundary()
        try await irPoisonedLegacyHistory(responses: false)
        let restore2 = try useResponses()
        do { try await irPoisonedLegacyHistory(responses: true) }
        restore2()
        try await irTransferRows()
    }

    private func irRejectedToolTurn(_ tag: String, responses: Bool, path: String, final: String = "done") {
        server.script([
            tools([(id: "\(tag)-read", name: "read_file", args: ["path": path])], responses: responses),
            Self.irRejection(responses: responses), text(final, responses: responses),
        ], statuses: [200, 400, 200])
    }

    /// R3: a failed checkpoint write or a failed conversation write → no
    /// resend; the turn fails with today's error; no notice.
    private func irWriteFailures() async throws {
        // Checkpoint (plain salvage file) write fails during the commit.
        do {
            let (manager, channel) = await irFresh()
            let path = irFile("R3a.png", IRFixtures.png)
            irRejectedToolTurn("R3a", responses: false, path: path)
            let image = irBase64(IRFixtures.png)
            server.requestObserver = { request in
                if String(decoding: request.body, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/").contains(image) {
                    ConversationManager.plainSalvageFaultForTesting = { throw IRInjected() }
                }
            }
            manager._testStartTurn(for: user("R3a read"))
            _ = await manager._testAwaitIdle(timeout: 30)
            ConversationManager.plainSalvageFaultForTesting = nil
            server.requestObserver = nil
            let error = channel.delivered.first { $0.hasPrefix("❌ Something went wrong") } ?? ""
            check("R3a checkpoint write failed: no resend, today's error, no notice, no mark saved",
                  irRequestBodies().count == 2 && error.contains("API error: HTTP 400") && irNotices(channel).isEmpty
                    && !irSavedConversation().contains("providerRejected"), "requests \(irRequestBodies().count) \(error)")
        }
        // Conversation write fails after the checkpoint was written.
        for responses in [false, true] {
            let restore: (() -> Void)? = responses ? try useResponses() : nil
            let tag = responses ? "R3br" : "R3b"
            let (manager, channel) = await irFresh()
            irRejectedToolTurn(tag, responses: responses, path: irFile("\(tag).png", IRFixtures.png))
            ConversationManager.imageRejectionBoundaryForTesting = { stage in
                guard stage == "afterCheckpoint" else { return }
                ConversationManager.historyWriteFaultForTesting = {
                    ConversationManager.historyWriteFaultForTesting = nil
                    throw IRInjected()
                }
            }
            manager._testStartTurn(for: user("\(tag) read"))
            _ = await manager._testAwaitIdle(timeout: 30)
            ConversationManager.imageRejectionBoundaryForTesting = nil
            ConversationManager.historyWriteFaultForTesting = nil
            let error = channel.delivered.first { $0.hasPrefix("❌ Something went wrong") } ?? ""
            check("\(tag) conversation write failed: no resend, today's error, no notice",
                  irRequestBodies().count == 2 && error.contains(responses ? "Responses HTTP 400" : "API error: HTTP 400")
                    && irNotices(channel).isEmpty, "requests \(irRequestBodies().count) \(error)")
            restore?()
        }
    }

    /// The files a crash at a save boundary leaves behind.
    private func irCrashFiles(_ manager: ConversationManager) -> [URL] {
        [StoragePaths.dataRoot.appendingPathComponent("conversation.json"), manager._testSalvageURL, manager._testActiveTurnMarkerURL]
    }

    /// Captures the crash files at `stage`, runs the turn to completion,
    /// then puts the captured files back (the state a crash would leave).
    private func irCrashAt(_ stage: String, manager: ConversationManager, run: () async -> Void) async -> Bool {
        let stash = StoragePaths.dataRoot.appendingPathComponent("ir-stash-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: stash, withIntermediateDirectories: true)
        let files = irCrashFiles(manager)
        var captured = false
        ConversationManager.imageRejectionBoundaryForTesting = { seen in
            guard seen == stage, !captured else { return }
            captured = true
            for file in files where FileManager.default.fileExists(atPath: file.path) {
                try? FileManager.default.copyItem(at: file, to: stash.appendingPathComponent(file.lastPathComponent))
            }
        }
        await run()
        ConversationManager.imageRejectionBoundaryForTesting = nil
        for file in files {
            try? FileManager.default.removeItem(at: file)
            let saved = stash.appendingPathComponent(file.lastPathComponent)
            if FileManager.default.fileExists(atPath: saved.path) { try? FileManager.default.copyItem(at: saved, to: file) }
        }
        try? FileManager.default.removeItem(at: stash)
        return captured
    }

    /// R4: restart at each save boundary of an active tool image. After the
    /// checkpoint write the recovered round already carries the mark; after
    /// the conversation write too. Startup recovery publishes the round and
    /// the resumed request sends the note, never the image.
    private func irBoundaryRestart(responses: Bool) async throws {
        for stage in ["afterCheckpoint", "afterConversation"] {
            let tag = (responses ? "R4r-" : "R4-") + stage
            let (manager, _) = await irFresh()
            let path = irFile("\(tag).png", IRFixtures.png)
            irRejectedToolTurn(tag, responses: responses, path: path)
            let captured = await irCrashAt(stage, manager: manager) {
                manager._testStartTurn(for: user("\(tag) read"))
                _ = await manager._testAwaitIdle(timeout: 30)
            }
            server.clear()
            server.script([text("\(tag) resumed", responses: responses)])
            let restarted = await restart()
            restarted._testStartupPasses()
            _ = await restarted._testAwaitIdle(timeout: 30)
            let body = irRequestBodies().first ?? ""
            let recovered = restarted._testMessages.flatMap { $0.toolInteractions.flatMap(\.results) }
                .contains { $0.fileAttachmentReferences.contains { $0.providerRejected == true } }
            check("\(tag): crash at the boundary → recovered round keeps the mark; the resumed request sends the note, not the image",
                  captured && recovered && body.contains(ModelImage.rejectedNote(path: path)) && !body.contains(irBase64(IRFixtures.png)),
                  "captured \(captured) recovered \(recovered) requests \(irRequestBodies().count)")
        }
    }

    /// Round 2: marks on an already-existing canonical user message. A
    /// crash before the conversation write repeats one free 400 (the mark was
    /// not yet durable); after it the exclusion holds.
    private func irUserImageBoundary() async throws {
        for stage in ["afterCheckpoint", "afterConversation"] {
            let tag = "R4u-" + stage
            let name = irUserImage("\(tag).png", IRFixtures.png)
            let old = Message(role: .user, content: "\(tag) old", imageFileNames: [name])
            let (manager, _) = await irFresh(history: [old, Message(role: .assistant, content: "ok")])
            server.script([Self.irRejection(responses: false), text("done", responses: false)], statuses: [400, 200])
            let captured = await irCrashAt(stage, manager: manager) {
                manager._testStartTurn(for: user("\(tag) new"))
                _ = await manager._testAwaitIdle(timeout: 30)
            }
            server.clear()
            server.script([Self.irRejection(responses: false), text("again", responses: false)], statuses: [400, 200])
            let restarted = await restart()
            restarted._testStartupPasses()
            _ = await restarted._testAwaitIdle(timeout: 30)
            let bodies = irRequestBodies()
            let image = irBase64(IRFixtures.png)
            if stage == "afterCheckpoint" {
                check("\(tag): mark not yet durable → the resumed request repeats one rejection and recovers again",
                      captured && bodies.count == 2 && bodies[0].contains(image) && !bodies[1].contains(image), "requests \(bodies.count)")
            } else {
                check("\(tag): durable mark on the existing message → the resumed request omits the image",
                      captured && !bodies.isEmpty && !bodies[0].contains(image)
                        && restarted._testMessages.first { $0.id == old.id }?.providerRejectedImageFileNames == [name],
                      "requests \(bodies.count)")
            }
        }
    }

    /// P5: a v0.2.51 history already holding a BMP tool attachment (how the
    /// benchmark frame was stored) is converted at the provider boundary, or
    /// replaced by an honest note where no converter exists — never sent raw.
    private func irPoisonedLegacyHistory(responses: Bool) async throws {
        let tag = responses ? "P5r" : "P5"
        let bmpPath = irFile("\(tag)-frame.bmp", IRFixtures.bmp(width: 32, height: 20))
        var result = ToolResultMessage(toolCallId: "\(tag)-legacy", content: #"{"success":true}"#)
        result.fileAttachmentReferences = [FileAttachmentReference(filename: "frame.bmp", mimeType: "image/bmp",
                                                                   snapshotPath: bmpPath, sourcePath: bmpPath)]
        let round = ToolInteraction(assistantMessage: AssistantToolCallMessage(content: nil, toolCalls: [
            ToolCall(id: "\(tag)-legacy", type: "function", function: FunctionCall(name: "read_file", arguments: "{}"))]), results: [result])
        let history = [user("\(tag) old"), Message(role: .assistant, content: "saw it", toolInteractions: [round])]
        for noDecoder in [false, true] {
            let (manager, _) = await irFresh(history: history)
            ModelImage.simulateNoPlatformDecoderForTesting = noDecoder
            let converter = !noDecoder && (ModelImage.platformDecoderAvailable
                || PlatformImage.convertFirstFrame(data: IRFixtures.png, toJPEG: false, quality: 0.8) != nil)
            server.script([text("ok", responses: responses)])
            manager._testStartTurn(for: user("\(tag) next"))
            _ = await manager._testAwaitIdle(timeout: 30)
            ModelImage.simulateNoPlatformDecoderForTesting = false
            let body = irRequestBodies().first ?? ""
            if converter {
                check("\(tag) poisoned legacy BMP is sent converted (PNG), never as BMP",
                      body.contains("data:image/png;base64,") && !body.contains("data:image/bmp"))
            } else {
                check("\(tag)\(noDecoder ? " (no converter)" : "") poisoned legacy BMP → honest note, no image part",
                      body.contains("[image not sent: BMP images are not accepted") && !body.contains("data:image/bmp"))
            }
        }
    }

    /// R12: marks survive prune (the snapshot keeps the marked reference and
    /// the original file stays retrievable), the persisted encodings, and a
    /// full Mind export/import.
    private func irTransferRows() async throws {
        let (manager, _) = await irFresh()
        let path = irFile("R12.png", IRFixtures.png)
        irRejectedToolTurn("R12", responses: false, path: path)
        manager._testStartTurn(for: user("R12 read"))
        _ = await manager._testAwaitIdle(timeout: 30)
        // Mind export/import (full) carries the marks.
        let backup = FileManager.default.temporaryDirectory.appendingPathComponent("ir-mind-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: backup) }
        do {
            try await MindExportService.shared.exportMind(to: backup)
            try? FileManager.default.removeItem(at: StoragePaths.dataRoot.appendingPathComponent("conversation.json"))
            let staged = try await MindExportService.shared.stageMind(from: backup)
            try await MindExportService.shared.applyStagedMind(staged)
            check("R12a Mind export/import keeps the marks in conversation.json", irSavedConversation().contains("\"providerRejected\":true"))
        } catch {
            check("R12a Mind export/import keeps the marks", false, "\(error)")
        }
        let restarted = await restart()
        server.clear(); server.script([text("after import", responses: false)])
        restarted._testStartTurn(for: user("R12 after import"))
        _ = await restarted._testAwaitIdle(timeout: 30)
        check("R12b after the import the image stays excluded", !(irRequestBodies().first ?? "").contains(irBase64(IRFixtures.png)))
        // Prune (the real commit with a scripted summary): the snapshot keeps
        // the marked reference; the original file stays.
        if let index = restarted._testMessages.firstIndex(where: { !$0.toolInteractions.isEmpty }) {
            _ = try? await restarted._testRetentionPrune(affected: [index], trigger: "manual", summary: "R12 pruned work")
        }
        let entries = (try? PruneArchiveStore.entries()) ?? []
        let snapshotText = entries.compactMap { try? String(contentsOf: PruneArchiveStore.root.appendingPathComponent($0.reference.basename), encoding: .utf8) }
            .joined()
        check("R12c the prune snapshot keeps the marked reference; the original file is still on disk",
              !entries.isEmpty && snapshotText.contains("providerRejected") && FileManager.default.fileExists(atPath: path),
              "snapshots \(entries.count)")
        // Encodings: unmarked records encode without the new keys; marked
        // ones round-trip; a malformed value decodes as absent.
        let plain = try JSONEncoder().encode(FileAttachmentReference(filename: "a.png", mimeType: "image/png"))
        var marked = FileAttachmentReference(filename: "a.png", mimeType: "image/png"); marked.providerRejected = true
        let back = try JSONDecoder().decode(FileAttachmentReference.self, from: JSONEncoder().encode(marked))
        let malformed = try JSONDecoder().decode(FileAttachmentReference.self,
                                                 from: Data(#"{"filename":"a.png","mimeType":"image/png","providerRejected":"yes"}"#.utf8))
        var message = Message(role: .user, content: "x", imageFileNames: ["p.png"]); message.providerRejectedImageFileNames = ["p.png"]
        let messageBack = try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(message))
        let plainMessage = try JSONEncoder().encode(Message(role: .user, content: "x"))
        check("R12d encodings: absent when unmarked, round-trip when marked, lenient on malformed values",
              !String(decoding: plain, as: UTF8.self).contains("providerRejected") && back.providerRejected == true
                && malformed.providerRejected == nil && messageBack.providerRejectedImageFileNames == ["p.png"]
                && !String(decoding: plainMessage, as: UTF8.self).contains("providerRejected"))
    }
}
