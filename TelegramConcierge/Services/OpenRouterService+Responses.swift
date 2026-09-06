import Foundation

extension OpenRouterService {
    func generateResponses(_ conversation: PreparedConversation,
                           context: ProviderExecutionContext) async throws -> LLMResponse {
        var input: [JSONValue] = [ResponsesAdapter.message(role: "system", text: conversation.systemPrompt)]
        var nonces = Set<String>(), usedCallIDs = Set<String>(), usedItemIDs = Set<String>()
        var replayBytes = 0
        // Reserve ongoing work first. Bound historical native cache entries as
        // complete rounds; their canonical text/calls/results still replay.
        // Ciphertext size is never converted into a token estimate.
        let current = conversation.toolResultMessages ?? []
        let currentBytes = current.reduce(0) { $0 + ($1.assistantMessage.responsesReplay?.byteCount ?? 0) }
        guard currentBytes <= ResponsesLimits.replayBytes else { throw ResponsesFailure.overflow }
        var remaining = ResponsesLimits.replayBytes - currentBytes
        var historical: [(String, Int)] = []
        for message in conversation.messages where message.role == .assistant {
            for (index, round) in message.toolInteractions.enumerated() {
                if let envelope = round.assistantMessage.responsesReplay {
                    historical.append(("\(message.id):\(index)", envelope.byteCount))
                }
            }
            if let envelope = message.responsesReplay { historical.append(("\(message.id):final", envelope.byteCount)) }
        }
        var nativeHistory = Set<String>()
        for (identity, bytes) in historical.reversed() {
            guard bytes <= remaining else { break }
            remaining -= bytes; nativeHistory.insert(identity)
        }
        if nativeHistory.count < historical.count {
            print("[Responses] Native replay cache bound: older complete rounds use canonical semantic replay")
        }

        func appendRound(_ interaction: ToolInteraction, identity: String) async throws {
            let assistant = interaction.assistantMessage
            let calls = assistant.toolCalls
            guard Set(calls.map(\.id)).count == calls.count,
                  Set(interaction.results.map(\.toolCallId)) == Set(calls.map(\.id)),
                  interaction.results.count == calls.count else {
                throw ResponsesFailure.malformed("unresolved historical tool call/result graph; prune the affected turn")
            }
            var native = ResponsesAdapter.nativeItems(envelope: identity.hasPrefix("current:") || nativeHistory.contains(identity) ? assistant.responsesReplay : nil,
                scope: context.responsesScope, text: assistant.content, calls: calls)
            if !usedCallIDs.isDisjoint(with: calls.map(\.id)) { native = nil }
            let itemIDs = native?.compactMap { $0.responsesObject?["id"]?.responsesString } ?? []
            if !usedItemIDs.isDisjoint(with: itemIDs) { native = nil }
            var mapped: [String: String] = [:]
            if let native {
                usedItemIDs.formUnion(itemIDs)
                input.append(contentsOf: native)
                for call in calls { mapped[call.id] = call.id; usedCallIDs.insert(call.id) }
                replayBytes += assistant.responsesReplay?.byteCount ?? 0
            } else {
                if assistant.responsesReplay != nil { print("[Responses] Replaying incompatible/edited round semantically; native reasoning omitted") }
                if let note = Self.responsesReasoningNote(reasoning: assistant.reasoning,
                                                         details: assistant.reasoningDetails) {
                    input.append(ResponsesAdapter.message(role: "system", text: note))
                }
                if let text = assistant.content, !text.isEmpty {
                    input.append(ResponsesAdapter.message(role: "assistant", text: MarkerNeutralizer.escape(text)))
                }
                for (index, call) in calls.enumerated() {
                    let id = "call_" + String(ResponsesReplayEnvelope.hash(Data("\(identity):\(index):\(call.id)".utf8)).prefix(40))
                    guard usedCallIDs.insert(id).inserted else { throw ResponsesFailure.malformed("replay call collision") }
                    mapped[call.id] = id
                    input.append(.object(["type": .string("function_call"), "call_id": .string(id),
                        "name": .string(call.function.name), "arguments": .string(MarkerNeutralizer.escape(call.function.arguments))]))
                }
            }
            for result in interaction.results {
                let text = try ProviderToolResultRenderer.wireText(for: result)
                // Render succeeded from typed state. Never infer receipt membership
                // by looking for marker-like text in tool/media/model content.
                for annotation in result.harnessAnnotations { nonces.insert(annotation.deliveryNonce) }
                var parts: [ContentPart] = []
                if !result.fileAttachments.isEmpty {
                    var visible: [String] = [], nonInline: [String] = []
                    for attachment in result.fileAttachments {
                        appendInlineAttachment(filename: attachment.filename, data: attachment.data,
                            mimeType: attachment.mimeType, contentParts: &parts, visibleFiles: &visible,
                            nonInlineFiles: &nonInline, renderPDFAsImages: true)
                    }
                    if !visible.isEmpty || !nonInline.isEmpty {
                        parts.append(.text(toolAttachmentText(visibleFiles: visible, nonInlineFiles: nonInline)))
                    }
                } else if !result.fileAttachmentReferences.isEmpty {
                    let restored = rehydrateAttachmentReferences(result.fileAttachmentReferences,
                        imagesDirectory: conversation.imagesDirectory, documentsDirectory: conversation.documentsDirectory,
                        renderPDFAsImages: true)
                    parts = restored.contentParts
                    parts.append(.text(toolAttachmentText(visibleFiles: restored.visibleFiles,
                        nonInlineFiles: restored.nonInlineFiles, missingFiles: restored.missingFiles)))
                }
                let media = try await responsesMedia(parts, textOnly: context.textOnly)
                var output: [JSONValue] = [.object(["type": .string("input_text"), "text": .string(text)])]
                if context.nativeToolMedia { output += media }
                input.append(.object(["type": .string("function_call_output"),
                    "call_id": .string(mapped[result.toolCallId]!), "output": .array(output)]))
                if !context.nativeToolMedia && !media.isEmpty {
                    input.append(.object(["role": .string("user"), "content": .array([
                        .object(["type": .string("input_text"), "text": .string("[Synthetic tool observation — not a user message. Media from tool call \(mapped[result.toolCallId]!).]")])
                    ] + media)]))
                }
            }
        }

        for message in conversation.messages {
            if message.role == .assistant {
                for (index, interaction) in message.toolInteractions.enumerated() {
                    try await appendRound(interaction, identity: "\(message.id):\(index)")
                }
                if message.toolInteractions.isEmpty, let log = message.compactToolLog, !log.isEmpty {
                    input.append(ResponsesAdapter.message(role: "assistant", text: MarkerNeutralizer.escape(log)))
                }
                if let native = ResponsesAdapter.nativeItems(envelope: nativeHistory.contains("\(message.id):final") ? message.responsesReplay : nil,
                    scope: context.responsesScope, text: message.content, calls: []),
                   usedItemIDs.isDisjoint(with: native.compactMap({ $0.responsesObject?["id"]?.responsesString })) {
                    usedItemIDs.formUnion(native.compactMap { $0.responsesObject?["id"]?.responsesString })
                    input.append(contentsOf: native)
                    replayBytes += message.responsesReplay?.byteCount ?? 0
                } else {
                    if let note = Self.responsesReasoningNote(reasoning: message.finalReasoning,
                                                             details: message.finalReasoningDetails) {
                        input.append(ResponsesAdapter.message(role: "system", text: note))
                    }
                    if !message.content.isEmpty {
                        input.append(ResponsesAdapter.message(role: "assistant", text: MarkerNeutralizer.escape(message.content)))
                    }
                }
            } else {
                var media: [ContentPart] = [], hints: [String] = []
                for name in message.imageFileNames + message.referencedImageFileNames {
                    let url = conversation.imagesDirectory.appendingPathComponent(name)
                    if !message.mediaPruned,
                       let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                       size <= ResponsesLimits.recordBytes, let data = try? Data(contentsOf: url) {
                        let mime = FilesystemTools.mimeType(forPath: url.path)
                        media.append(.image(.init(url: "data:\(mime.hasPrefix("image/") ? mime : "image/jpeg");base64,\(data.base64EncodedString())")))
                    }
                    hints.append("[Image: \(url.path) — use read_file if not visible]")
                }
                for name in message.documentFileNames + message.referencedDocumentFileNames {
                    hints.append(await documentPathHint(url: conversation.documentsDirectory.appendingPathComponent(name),
                        fileName: name, descriptor: "Document"))
                }
                let canonical = message.kind == .userText ? message.content : MarkerNeutralizer.escape(message.content)
                let text = (hints.isEmpty ? "" : MarkerNeutralizer.escape(hints.joined(separator: "\n")) + "\n") + canonical
                let parts = try await responsesMedia(media, textOnly: context.textOnly)
                input.append(.object(["role": .string("user"), "content": .array(parts + [
                    .object(["type": .string("input_text"), "text": .string(text)])])]))
            }
            if let metadata = await historyMetadataNote(for: message) {
                input.append(ResponsesAdapter.message(role: "system", text: MarkerNeutralizer.escape(metadata)))
            }
        }
        for (index, interaction) in (conversation.toolResultMessages ?? []).enumerated() {
            try await appendRound(interaction, identity: "current:\(index)")
        }
        guard replayBytes <= ResponsesLimits.replayBytes else { throw ResponsesFailure.overflow }
        if let tail = conversation.tailSystemMessage, !tail.isEmpty {
            input.append(ResponsesAdapter.message(role: "system", text: MarkerNeutralizer.escape(tail)))
        }
        if let tail = conversation.tailUserMessage, !tail.isEmpty {
            input.append(ResponsesAdapter.message(role: "user", text: MarkerNeutralizer.escape(tail)))
        }
        var ambient: [String] = []
        if let bash = await BackgroundProcessRegistry.shared.liveSummaryText() { ambient.append(bash) }
        if let subagents = await SubagentBackgroundRegistry.shared.liveSummary() { ambient.append(subagents) }
        if !ambient.isEmpty {
            input.append(ResponsesAdapter.message(role: "user", text: MarkerNeutralizer.escape(
                "[Ambient status — not a user message]\n" + ambient.joined(separator: "\n"))))
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let receipt = PreparedRequestReceipt(requestID: UUID(),
            historyFingerprint: ResponsesReplayEnvelope.hash(try encoder.encode(input)), deliveryNonces: nonces)
        return try await ResponsesAdapter(context: context).send(input: input, tools: conversation.tools, receipt: receipt)
    }

    /// Only readable Chat Completions reasoning crosses protocols. Never dump
    /// opaque provider objects, signatures, IDs or encrypted reasoning as text.
    /// Reuse the established system-voice wrapper without changing chat encoding.
    /// This is a request projection: persisted history and pruning stay canonical.
    static func responsesReasoningNote(reasoning: JSONValue?, details: JSONValue?) -> String? {
        let plain = reasoning?.responsesString.flatMap { $0.isEmpty ? nil : JSONValue.string($0) }
        let readable = (details?.responsesArray ?? []).compactMap { value -> JSONValue? in
            guard let item = value.responsesObject,
                  let type = item["type"]?.responsesString else { return nil }
            let field: String
            switch type {
            case "reasoning.text": field = "text"
            case "reasoning.summary": field = "summary"
            default: return nil
            }
            guard let text = item[field]?.responsesString, !text.isEmpty else { return nil }
            return .object(["type": .string(type), field: .string(text)])
        }
        let record = OpenRouterAPIMessage(role: "assistant", content: nil, reasoning: plain,
            reasoningDetails: readable.isEmpty ? nil : .array(readable))
        return record.sanitizedForProvider(.openAICompatible, useReasoningContent: false,
            reasoningFromCurrentModel: false).reasoningNote.map { MarkerNeutralizer.escape($0) }
    }

    /// Reuse media/OCR utilities, not the Chat Completions serializer. Conversion
    /// happens one result at a time so tool ownership cannot be lost.
    func responsesMedia(_ content: [ContentPart], textOnly: Bool) async throws -> [JSONValue] {
        var parts = content
        if textOnly && !parts.isEmpty {
            var holder = [OpenRouterAPIMessage(role: "user", content: .parts(parts))]
            try await preprocessMultimodalContent(in: &holder)
            parts = holder.flatMap { message in
                switch message.content {
                case .parts(let p): return p
                case .text(let s): return [.text(s)]
                case nil: return []
                }
            }
        }
        return parts.map { part in
            switch part {
            case .text(let text, _): return .object(["type": .string("input_text"), "text": .string(MarkerNeutralizer.escape(text))])
            case .image(let image): return .object(["type": .string("input_image"), "image_url": .string(image.url)])
            case .file(let file): return .object(["type": .string("input_file"), "file_data": .string(file.url), "filename": .string("attachment.pdf")])
            }
        }
    }
}
