import Foundation

/// Owner decision 2026-09-25: generated images are no longer sent to the user
/// automatically. The model sees the image (multimodal attachment) and shares
/// it with send_document_to_chat on the saved path. Runs the real ToolExecutor
/// (main agent and subagent), the real end-of-turn media drain and the real
/// in-app ChatChannel conformance; the image service is the OpenRouter lane
/// seam with a recording transport (no key, no network). Storage is the
/// suite's isolated XDG root.
extension ImageToolSelftest {
    static let explicitSendSentence = "The image is saved and shown to you; it is not sent to the user automatically — use send_document_to_chat to share it."

    /// What the in-app channel was asked to deliver, in order.
    final class DeliveryLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _photos: [(data: Data, caption: String?, mimeType: String)] = []
        private var _documents: [String] = []
        var photos: [(data: Data, caption: String?, mimeType: String)] { lock.lock(); defer { lock.unlock() }; return _photos }
        var documents: [String] { lock.lock(); defer { lock.unlock() }; return _documents }
        func photo(_ data: Data, _ caption: String?, _ mime: String) { lock.lock(); _photos.append((data, caption, mime)); lock.unlock() }
        func document(_ name: String) { lock.lock(); _documents.append(name); lock.unlock() }
    }

    /// The production end-of-turn drain, delivering through a real ChatChannel.
    @MainActor
    static func drainTurnMedia(into log: DeliveryLog) async throws -> Bool {
        let channel = AppLocalChannel(
            onPhoto: { data, caption, mime in log.photo(data, caption, mime) },
            onDocument: { _, filename, _, _ in log.document(filename) })
        return try await ConversationManager.deliverQueuedTurnMedia(
            stillCurrent: { true },
            sendPhoto: { data, caption, mime in try await channel.sendPhoto(chatId: "app", imageData: data, caption: caption, mimeType: mime) },
            sendDocument: { data, name, caption, mime in try await channel.sendDocument(chatId: "app", documentData: data, filename: name, caption: caption, mimeType: mime) })
    }

    func explicitSend(_ c: ResponsesSelftest.Checks) async throws {
        StoragePaths.ensureRoots()
        let images = StoragePaths.dataRoot.appendingPathComponent("images", isDirectory: true)
        let documents = StoragePaths.dataRoot.appendingPathComponent("documents", isDirectory: true)
        try PrivateStorage.ensureDirectory(images)
        try PrivateStorage.ensureDirectory(documents)

        // S1 — every generate_image schema variant says it is not sent automatically.
        var descriptions: [String: String] = [:]
        try MediaRoutingSelftest.set([KeychainHelper.imageGenerationProviderKey: "gemini"])
        descriptions["gemini"] = AvailableTools.generateImage.function.description
        try MediaRoutingSelftest.set(MediaRoutingSelftest.openAIKeys)
        descriptions["openai"] = AvailableTools.generateImage.function.description
        try MediaRoutingSelftest.set(MediaRoutingSelftest.orLane)
        descriptions["openrouter"] = AvailableTools.generateImage.function.description
        for (backend, text) in descriptions.sorted(by: { $0.key < $1.key }) {
            c.check("S1 \(backend) generate_image description: saved and shown to the model, not sent automatically, share with send_document_to_chat",
                    text.contains(Self.explicitSendSentence) && !text.contains("will be sent to the user")
                    && text.components(separatedBy: "send_document_to_chat").count == 2)
        }
        c.check("S1 the three variants are distinct schemas (the backend decision still selects them)",
                Set(descriptions.values).count == 3 && descriptions["openrouter"]?.contains("through OpenRouter") == true
                && descriptions["openai"]?.contains("GPT Image 2.5") == true && descriptions["gemini"]?.contains("using Gemini") == true)

        // Real executor through the OpenRouter-lane seam (recording transport).
        let png = Data(base64Encoded: MediaRoutingSelftest.pngBase64)!
        let ok = #"{"choices":[{"message":{"content":"","images":[{"type":"image_url","image_url":{"url":"data:image/png;base64,\#(MediaRoutingSelftest.pngBase64)"}}]}}],"usage":{"cost":0.01}}"#
        let recorder = MediaRoutingSelftest.Recorder { _ in (200, Data(ok.utf8)) }
        ToolExecutor.openRouterImageServiceOverrideForTesting = OpenRouterImageService(transport: recorder.transport)
        defer { ToolExecutor.openRouterImageServiceOverrideForTesting = nil }
        _ = ToolExecutor.getPendingDocuments()

        func generate(_ executor: ToolExecutor, id: String) async throws -> (ToolResultMessage, [String: Any]) {
            let call = ToolCall(id: id, type: "function", function: FunctionCall(name: "generate_image", arguments: #"{"prompt":"A red bicycle","engine":"fast"}"#))
            let result = try await executor.execute(call)
            let object = (try? JSONSerialization.jsonObject(with: Data(result.content.utf8))) as? [String: Any] ?? [:]
            return (result, object)
        }

        // S2 — main agent: result names the saved path, says it was NOT shown, points at send_document_to_chat.
        let main = ToolExecutor(outputMode: .mainAgent)
        let (mainResult, mainObject) = try await generate(main, id: "gen-main")
        let path = mainObject["path"] as? String ?? ""
        let filename = mainObject["filename"] as? String ?? ""
        let message = mainObject["message"] as? String ?? ""
        c.check("S2 main result: success, absolute saved path = documents/<filename>, file on disk with the generated bytes",
                mainObject["success"] as? Bool == true && path.hasPrefix("/") && !filename.isEmpty
                && path == documents.appendingPathComponent(filename).path
                && (try? Data(contentsOf: URL(fileURLWithPath: path))) == png)
        c.check("S2 main result message: seen by the model, NOT shown to the user, share with send_document_to_chat file_path = this path",
                message.contains("You can now see and analyze the result.") && message.contains("It has NOT been shown to the user")
                && message.contains("Saved to \(path).") && message.contains("call send_document_to_chat with file_path set to this path"))
        c.check("S2 raw result text carries the path unescaped (no \\/ slashes)",
                mainResult.content.contains("\"path\":\"\(path)\"") && !mainResult.content.contains("\\/"))
        c.check("S2 the image is still attached for the model (same bytes, image/png, source path = the saved path)",
                mainResult.fileAttachments.count == 1 && mainResult.fileAttachments.first?.data == png
                && mainResult.fileAttachments.first?.mimeType == "image/png" && mainResult.fileAttachments.first?.sourcePath == path)

        // S3 — nothing turn-scoped is queued, and the end-of-turn drain sends nothing.
        let noSend = DeliveryLog()
        let current = try await Self.drainTurnMedia(into: noSend)
        c.check("S3 after generate_image the turn ends with no photo and no document sent",
                current && noSend.photos.isEmpty && noSend.documents.isEmpty)
        // A [SKIP] ambient turn runs the same drain (media drains even on
        // silent turns) and a turn with no reply channel drops the queue:
        // with nothing queued, neither sends nor drops a generated image.
        _ = try await generate(main, id: "gen-silent")
        c.check("S3 [SKIP] / no-reply-channel turns: a second generation leaves nothing queued to send or drop",
                ToolExecutor.getPendingDocuments().isEmpty)

        // S4 — send_document_to_chat with that path is how the image reaches the user: as a photo.
        let send = ToolCall(id: "send-main", type: "function", function: FunctionCall(name: "send_document_to_chat",
            arguments: String(data: try JSONSerialization.data(withJSONObject: ["file_path": path, "caption": "Your bicycle"]), encoding: .utf8)!))
        let sendResult = try await main.execute(send)
        let delivered = DeliveryLog()
        _ = try await Self.drainTurnMedia(into: delivered)
        c.check("S4 send_document_to_chat(file_path: saved path) → exactly one PHOTO, same bytes, image/png, caption kept, no document",
                sendResult.content.contains("\"success\" : true") && delivered.photos.count == 1 && delivered.documents.isEmpty
                && delivered.photos.first?.data == png && delivered.photos.first?.mimeType == "image/png"
                && delivered.photos.first?.caption == "Your bicycle")
        c.check("S4 the queue is drained after delivery (nothing leaks into the next turn)",
                ToolExecutor.getPendingDocuments().isEmpty)
        for ext in ["jpg", "webp"] {
            let other = documents.appendingPathComponent("generated_fixture.\(ext)")
            try PrivateStorage.writeAtomically(png, to: other)
            let otherCall = ToolCall(id: "send-\(ext)", type: "function", function: FunctionCall(name: "send_document_to_chat",
                arguments: String(data: try JSONSerialization.data(withJSONObject: ["file_path": other.path]), encoding: .utf8)!))
            _ = try await main.execute(otherCall)
            let log = DeliveryLog()
            _ = try await Self.drainTurnMedia(into: log)
            c.check("S4 a generated .\(ext) path is also sent as a photo", log.photos.count == 1 && log.documents.isEmpty)
        }

        // S5 — subagent: same attachment and path, but told to return the path (it has no chat).
        let sub = ToolExecutor(outputMode: .subagent)
        let (subResult, subObject) = try await generate(sub, id: "gen-sub")
        let subPath = subObject["path"] as? String ?? ""
        let subMessage = subObject["message"] as? String ?? ""
        c.check("S5 subagent result: saved path present, NOT shown to the user, return the path; never told to call send_document_to_chat",
                !subPath.isEmpty && FileManager.default.fileExists(atPath: subPath)
                && subMessage.contains("It has NOT been shown to the user") && subMessage.contains("include this path in your final result")
                && !subMessage.contains("send_document_to_chat"))
        c.check("S5 subagent still sees the image (attachment present)",
                subResult.fileAttachments.count == 1 && subResult.fileAttachments.first?.data == png)
        let subDrain = DeliveryLog()
        _ = try await Self.drainTurnMedia(into: subDrain)
        c.check("S5 a subagent's image queues nothing for the parent turn",
                subDrain.photos.isEmpty && subDrain.documents.isEmpty)

        // S6 — save failure: no path is offered and the model is told it cannot be sent.
        let unsaved = ToolExecutor.generatedImageMessage(isEdit: true, savedPath: nil, canSendToChat: true)
        c.check("S6 unsaved image: says transformed, not shown, cannot be sent; offers no tool call",
                unsaved.hasPrefix("Image transformed successfully.") && unsaved.contains("NOT been shown")
                && unsaved.contains("cannot be sent") && !unsaved.contains("send_document_to_chat"))
    }
}
