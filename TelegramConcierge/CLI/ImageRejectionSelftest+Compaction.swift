import Foundation

/// R5 (plan v2 §2.5, Codex round 2): a rejection inside a COMPACTED active
/// turn. The checkpoint is then an envelope (generation > 0) whose retained
/// rounds were renumbered by the compaction; the mark lives on the retained
/// round's reference, so the immediate retry, the saved outcome and a
/// restart from the envelope all omit the image. Also P4 (app ingestion).
extension MidturnHarness {

    /// Reads a large file until a real active-turn compaction ran, then reads
    /// the image; the next request is rejected once; then the turn ends.
    final class IRCompactionScript: @unchecked Sendable {
        private let lock = NSLock()
        let responses: Bool, large: String, image: String, imageBase64: String
        private(set) var phase = "reading"
        private var ordinary = 0
        private var status: Int?
        private(set) var rejectedBody = ""
        private(set) var retryBody = ""
        init(responses: Bool, large: String, image: String, imageBase64: String) {
            self.responses = responses; self.large = large; self.image = image; self.imageBase64 = imageBase64
        }
        var currentPhase: String { lock.lock(); defer { lock.unlock() }; return phase }

        func route(_ request: CapturedHTTPRequest) -> (body: String, delay: TimeInterval)? {
            let text = String(decoding: request.body, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
            let tokens = request.body.count / 3
            lock.lock(); defer { lock.unlock() }
            status = nil
            func reply(_ t: String?, _ calls: [(id: String, name: String, args: [String: Any])]) -> (body: String, delay: TimeInterval)? {
                (MidturnHarness.CompactionScript.reply(responses: responses, text: t, calls: calls, tokens: tokens), 0)
            }
            if text.contains("ACTIVE TURN COMPACTION") {
                if phase == "reading" { phase = "compacted" }
                return reply("Goal: read the file repeatedly.", [])
            }
            if text.contains("[PRUNE SUMMARY") { return reply("Earlier turn summary.", []) }
            ordinary += 1
            switch phase {
            case "reading":
                guard ordinary < 60 else { phase = "gaveup"; return reply("IR5_GAVE_UP", []) }
                return reply(nil, [(id: "r\(ordinary)", name: "read_file", args: ["path": large, "limit": 200])])
            case "compacted":
                phase = "imageRead"
                return reply(nil, [(id: "img", name: "read_file", args: ["path": image])])
            case "imageRead":
                if text.contains(imageBase64) {
                    phase = "rejected"; rejectedBody = text; status = 400
                    return (responses ? IRFixtures.openAIResponsesBMP : IRFixtures.openAIChatBMP, 0)
                }
                return reply("IR5_NO_IMAGE_SENT", [])
            case "rejected":
                retryBody = text; phase = "done"
                return reply("IR5_FINAL", [])
            default:
                return reply("IR5_AFTER", [])
            }
        }
        func routedStatus(_ request: CapturedHTTPRequest) -> Int? { lock.lock(); defer { lock.unlock() }; return status }
    }

    func irRestartSection() async throws {
        try KeychainHelper.saveBatch([KeychainHelper.maxContextTokensKey: "250000", KeychainHelper.targetContextTokensKey: "70000",
                                      KeychainHelper.archiveChunkSizeKey: "1000000"].mapValues { Optional($0) })
        defer {
            for key in [KeychainHelper.maxContextTokensKey, KeychainHelper.targetContextTokensKey, KeychainHelper.archiveChunkSizeKey] {
                try? KeychainHelper.delete(key: key)
            }
        }
        let large = irFile("ir5-large.txt", Data(((0..<100).map { _ in String(repeating: "EXACT_EVIDENCE ", count: 55) }.joined(separator: "\n")).utf8))
        try await irCompacted(responses: false, large: large)
        let restore = try useResponses()
        do { try await irCompacted(responses: true, large: large) }
        restore()
    }

    private func irCompacted(responses: Bool, large: String) async throws {
        let tag = responses ? "R5r" : "R5"
        let (manager, channel) = await irFresh()
        let image = irFile("\(tag).png", IRFixtures.png)
        let script = IRCompactionScript(responses: responses, large: large, image: image, imageBase64: irBase64(IRFixtures.png))
        server.router = { script.route($0) }
        server.routedStatus = { script.routedStatus($0) }
        // Crash capture at the checkpoint boundary of the envelope commit.
        let stash = StoragePaths.dataRoot.appendingPathComponent("ir5-stash-\(tag)", isDirectory: true)
        try? FileManager.default.createDirectory(at: stash, withIntermediateDirectories: true)
        let crashFiles = [StoragePaths.dataRoot.appendingPathComponent("conversation.json"), manager._testSalvageURL, manager._testActiveTurnMarkerURL]
        var captured = false
        ConversationManager.imageRejectionBoundaryForTesting = { stage in
            guard stage == "afterCheckpoint", !captured else { return }
            captured = true
            for file in crashFiles where FileManager.default.fileExists(atPath: file.path) {
                try? FileManager.default.copyItem(at: file, to: stash.appendingPathComponent(file.lastPathComponent))
            }
        }
        manager._testStartTurn(for: user("\(tag) read the file many times, then the image"))
        _ = await manager._testAwaitIdle(timeout: 240)
        ConversationManager.imageRejectionBoundaryForTesting = nil
        let outcome = manager._testMessages.last { $0.role == .assistant }
        let marked = outcome?.toolInteractions.flatMap(\.results).first { $0.toolCallId == "img" }?
            .fileAttachmentReferences.first?.providerRejected == true
        check("\(tag)a a real compaction ran, then the rejection; the retry omits the image and the turn ends",
              outcome?.activeTurnCompaction != nil && outcome?.content == "IR5_FINAL"
                && script.rejectedBody.contains(irBase64(IRFixtures.png)) && !script.retryBody.contains(irBase64(IRFixtures.png))
                && script.retryBody.contains(ModelImage.rejectedNote(path: image)),
              "phase \(script.currentPhase) last \(outcome?.content.prefix(60) ?? "nil")")
        check("\(tag)b the saved outcome's retained (renumbered) round keeps the mark; one notice",
              marked && irSavedConversation().contains("\"providerRejected\":true") && irNotices(channel).count == 1)
        // Restart from the envelope captured right after its write.
        for file in crashFiles {
            try? FileManager.default.removeItem(at: file)
            let saved = stash.appendingPathComponent(file.lastPathComponent)
            if FileManager.default.fileExists(atPath: saved.path) { try? FileManager.default.copyItem(at: saved, to: file) }
        }
        try? FileManager.default.removeItem(at: stash)
        server.clear()
        let restarted = await restart()
        restarted._testStartupPasses()
        _ = await restarted._testAwaitIdle(timeout: 60)
        // Startup publishes the compacted work as an interrupted outcome
        // (compacted turns are not auto-resumed); the next request is the
        // user's next message, which replays the recovered rounds.
        let recoveredMark = restarted._testMessages.flatMap { $0.toolInteractions.flatMap(\.results) }
            .first { $0.toolCallId == "img" }?.fileAttachmentReferences.first?.providerRejected == true
        restarted._testStartTurn(for: user("\(tag) continue"))
        _ = await restarted._testAwaitIdle(timeout: 60)
        let resumed = irRequestBodies().first { !$0.contains("ACTIVE TURN COMPACTION") && !$0.contains("[PRUNE SUMMARY") } ?? ""
        check("\(tag)c crash right after the envelope checkpoint write → startup recovers the marked round; the next request omits the image",
              captured && recoveredMark && !resumed.isEmpty && !resumed.contains(irBase64(IRFixtures.png)) && resumed.contains(ModelImage.rejectedNote(path: image)),
              "captured \(captured) requests \(irRequestBodies().count) blocked \(restarted._testRecoveryBlocked) last \(restarted._testMessages.last?.content.prefix(80) ?? "nil") count \(restarted._testMessages.count) marker \(FileManager.default.fileExists(atPath: restarted._testActiveTurnMarkerURL.path))")
        server.router = nil
        server.routedStatus = nil
    }

    /// P4: images arriving through the phone-app socket in formats providers
    /// refuse are stored converted, the original kept as a document; a
    /// supported image stays untouched; without a converter the file is
    /// filed as a document only.
    func irIngestSection() async throws {
        let (manager, _) = await irFresh()
        manager._testSetPolling(true)
        let tiff = irFile("ingest.tiff", IRFixtures.tiff)
        let jpeg = irFile("ingest.jpg", IRFixtures.jpeg)
        var attachments = [URL(fileURLWithPath: tiff), URL(fileURLWithPath: jpeg)]
        let heic = IRFixtures.heic().map { irFile("ingest.heic", $0) }
        if let heic { attachments.append(URL(fileURLWithPath: heic)) }
        server.script([Self.chatText("got them")])
        _ = await manager.sendFromApp(text: "P4 files", attachments: attachments)
        _ = await manager._testAwaitIdle(timeout: 30)
        let message = manager._testMessages.first { $0.content == "P4 files" }
        let images = message?.imageFileNames ?? [], documents = message?.documentFileNames ?? []
        let converter = ModelImage.platformDecoderAvailable || PlatformImage.convertFirstFrame(data: IRFixtures.png, toJPEG: false, quality: 0.8) != nil
        let imagesDir = StoragePaths.dataRoot.appendingPathComponent("images")
        let docsDir = StoragePaths.dataRoot.appendingPathComponent("documents")
        let jpegKept = images.contains { (try? Data(contentsOf: imagesDir.appendingPathComponent($0))) == IRFixtures.jpeg }
        let tiffOriginal = documents.contains { (try? Data(contentsOf: docsDir.appendingPathComponent($0))) == IRFixtures.tiff }
        if converter {
            check("P4 app socket: TIFF stored converted (PNG) + original kept as a document; JPEG untouched",
                  jpegKept && tiffOriginal && images.contains { $0.hasSuffix(".png") }, "images \(images) documents \(documents)")
            if heic != nil {
                check("P4 app socket: HEIC stored converted (JPEG) + original kept as a document",
                      images.filter { $0.hasSuffix(".jpg") }.count == 2 && documents.contains { $0.hasSuffix(".heic") }, "images \(images)")
            }
        }
        // Without any converter the unsupported file becomes a document only.
        let (other, _) = await irFresh()
        other._testSetPolling(true)
        ModelImage.simulateNoPlatformDecoderForTesting = true
        server.script([Self.chatText("noted")])
        _ = await other.sendFromApp(text: "P4 bmp", attachments: [URL(fileURLWithPath: irFile("ingest.bmp", IRFixtures.bmp(width: 8, height: 8)))])
        _ = await other._testAwaitIdle(timeout: 30)
        ModelImage.simulateNoPlatformDecoderForTesting = false
        let bmpMessage = other._testMessages.first { $0.content == "P4 bmp" }
        check("P4 without a converter: the BMP is filed as a document, not an image",
              bmpMessage?.imageFileNames.isEmpty == true && bmpMessage?.documentFileNames.count == 1)
    }
}
