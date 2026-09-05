import Foundation

extension OpenRouterService {
    /// Legacy rendering order, including synthetic user-role tool media and
    /// annotation validation, is deliberately confined to this chat adapter.
    /// Responses must consume canonical PreparedConversation input separately.
    func generateChatCompletion(
        _ conversation: PreparedConversation, context: ProviderExecutionContext
    ) async throws -> LLMResponse {
        let systemPrompt = conversation.systemPrompt
        let truncatedMessages = conversation.messages
        let imagesDirectory = conversation.imagesDirectory
        let documentsDirectory = conversation.documentsDirectory
        let toolResultMessages = conversation.toolResultMessages
        let tailSystemMessage = conversation.tailSystemMessage
        let tailUserMessage = conversation.tailUserMessage
        var apiMessages: [OpenRouterAPIMessage] = []

        apiMessages.append(OpenRouterAPIMessage(
            role: "system",
            content: .text(systemPrompt)
        ))

        // Date formatters for timestamps
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"

        let dateHeaderFormatter = DateFormatter()
        dateHeaderFormatter.dateFormat = "EEEE, d MMMM yyyy"

        let calendar = Calendar.current
        var lastMessageDate: Date? = nil

        // Convert conversation messages, interleaving stored tool interactions
        for message in truncatedMessages {
            // Tool run log messages are system metadata, not model output.
            // Sending them as "assistant" causes Claude to mimic the log format
            // instead of actually invoking tools.
            let isToolRunLog = message.role == .assistant && message.content.hasPrefix("[TOOL RUN LOG")
            let role = message.role == .user ? "user" : (isToolRunLog ? "system" : "assistant")

            // Final-response reasoning rides on the assistant's visible text
            // message so the model sees what it thought before it answered.
            // Cleared by the Watermark pruner together with tool interactions.
            let historyReasoning = role == "assistant" ? message.finalReasoning : nil
            let historyReasoningDetails = role == "assistant" ? message.finalReasoningDetails : nil

            // For assistant messages with stored tool interactions, emit the interactions
            // BEFORE the final text so the model sees the full reasoning chain
            if message.role == .assistant && !isToolRunLog && !message.toolInteractions.isEmpty {
                for interaction in message.toolInteractions {
                    apiMessages.append(OpenRouterAPIMessage(
                        role: "assistant",
                        content: interaction.assistantMessage.content.map { .text($0) },
                        toolCalls: interaction.assistantMessage.toolCalls,
                        reasoning: interaction.assistantMessage.reasoning,
                        reasoningDetails: interaction.assistantMessage.reasoningDetails,
                        producedByModel: interaction.assistantMessage.producedByModel
                    ))
                    var currentInteractionReferences: [FileAttachmentReference] = []
                    for result in interaction.results {
                        // Single provider boundary for tool text: re-neutralize
                        // ordinary content, render typed annotations
                        // (MIDTURN_NONCE_PLAN §8 step 12).
                        apiMessages.append(OpenRouterAPIMessage(
                            role: "tool",
                            content: .text(try ProviderToolResultRenderer.wireText(for: result)),
                            toolCallId: result.toolCallId
                        ))
                        currentInteractionReferences.append(contentsOf: result.fileAttachmentReferences)
                    }

                    if !currentInteractionReferences.isEmpty {
                        let rehydrated = rehydrateAttachmentReferences(
                            currentInteractionReferences,
                            imagesDirectory: imagesDirectory,
                            documentsDirectory: documentsDirectory,
                            renderPDFAsImages: context.renderPDFAsImages
                        )

                        if !rehydrated.contentParts.isEmpty || !rehydrated.missingFiles.isEmpty || !rehydrated.nonInlineFiles.isEmpty {
                            var parts = rehydrated.contentParts
                            parts.append(.text(toolAttachmentText(
                                visibleFiles: rehydrated.visibleFiles,
                                nonInlineFiles: rehydrated.nonInlineFiles,
                                missingFiles: rehydrated.missingFiles
                            )))
                            apiMessages.append(OpenRouterAPIMessage(role: "user", content: .parts(parts)))
                        }
                    }
                }
            } else if message.role == .assistant && !isToolRunLog && message.toolInteractions.isEmpty,
                      let compactLog = message.compactToolLog, !compactLog.isEmpty {
                // Interactions were pruned — emit the compact log as system
                // context (model-summarized tool output: untrusted-derived).
                apiMessages.append(OpenRouterAPIMessage(role: "system", content: .text(MarkerNeutralizer.escape(compactLog))))
            }

            // Check if we need to add a date header (new day)
            var dateHeader = ""
            if let lastDate = lastMessageDate {
                if !calendar.isDate(lastDate, inSameDayAs: message.timestamp) {
                    // New day - add date header
                    dateHeader = "--- \(dateHeaderFormatter.string(from: message.timestamp)) ---\n"
                }
            } else {
                // First message - add date header
                dateHeader = "--- \(dateHeaderFormatter.string(from: message.timestamp)) ---\n"
            }
            lastMessageDate = message.timestamp

            // Format time for this message
            let timePrefix = "[\(timeFormatter.string(from: message.timestamp))] "

            // Check if message has multimodal content (images or documents, including referenced ones)
            let hasImages = !message.imageFileNames.isEmpty
            let hasDocuments = !message.documentFileNames.isEmpty
            let hasReferencedImages = !message.referencedImageFileNames.isEmpty
            let hasReferencedDocuments = !message.referencedDocumentFileNames.isEmpty
            let hasMultimodal = hasImages || hasDocuments || hasReferencedImages || hasReferencedDocuments

            if hasMultimodal {
                // Multimodal message: inline base64 data for files still on disk,
                // text-only hints when media has been pruned by the watermark system
                // or when files have been cleaned up from disk.
                let shouldInline = !message.mediaPruned
                var contentParts: [ContentPart] = []
                var textHints: [String] = []

                // Referenced images (context from replied-to messages)
                for refImageFileName in message.referencedImageFileNames {
                    let imageURL = imagesDirectory.appendingPathComponent(refImageFileName)
                    if shouldInline, let imageData = try? Data(contentsOf: imageURL) {
                        let base64String = imageData.base64EncodedString()
                        let resolvedMime = FilesystemTools.mimeType(forPath: imageURL.path)
                        let mimeType = resolvedMime.hasPrefix("image/") ? resolvedMime : "image/jpeg"
                        let dataURL = "data:\(mimeType);base64,\(base64String)"
                        contentParts.append(.image(ImageURL(url: dataURL)))
                        textHints.append("[Referenced image: \(imageURL.path)]")
                    } else {
                        let desc = await FileDescriptionService.shared.get(filename: refImageFileName)
                        let descSuffix = desc != nil ? " — \"\(desc!)\"" : ""
                        textHints.append("[Referenced image: \(imageURL.path)\(descSuffix) — use read_file to view]")
                    }
                }

                // Referenced documents (context from replied-to messages): path-only
                // hint — documents are never auto-inlined (see documentPathHint).
                for refDocFileName in message.referencedDocumentFileNames {
                    let documentURL = documentsDirectory.appendingPathComponent(refDocFileName)
                    textHints.append(await documentPathHint(url: documentURL, fileName: refDocFileName, descriptor: "Referenced document"))
                }

                // Primary images
                for imageFileName in message.imageFileNames {
                    let imageURL = imagesDirectory.appendingPathComponent(imageFileName)
                    if shouldInline, let imageData = try? Data(contentsOf: imageURL) {
                        let base64String = imageData.base64EncodedString()
                        let resolvedMime = FilesystemTools.mimeType(forPath: imageURL.path)
                        let mimeType = resolvedMime.hasPrefix("image/") ? resolvedMime : "image/jpeg"
                        let dataURL = "data:\(mimeType);base64,\(base64String)"
                        contentParts.append(.image(ImageURL(url: dataURL)))
                        textHints.append("[Image: \(imageURL.path)]")
                    } else {
                        let desc = await FileDescriptionService.shared.get(filename: imageFileName)
                        let descSuffix = desc != nil ? " — \"\(desc!)\"" : ""
                        textHints.append("[Image: \(imageURL.path)\(descSuffix) — use read_file to view]")
                    }
                }

                // Primary documents (PDFs, text files, etc.): path-only hint —
                // documents are never auto-inlined (see documentPathHint).
                for documentFileName in message.documentFileNames {
                    let documentURL = documentsDirectory.appendingPathComponent(documentFileName)
                    textHints.append(await documentPathHint(url: documentURL, fileName: documentFileName, descriptor: "Document"))
                }

                // Build text content with hints and user message. Hints carry
                // untrusted-derived text (file paths, model-generated
                // descriptions) — neutralize the reserved harness marker.
                // Envelope-kind messages (email/subagent/bash/reminder) carry
                // untrusted interiors and are neutralized too; the human's own
                // typed text (.userText) stays byte-intact.
                var textContent = message.kind == .userText
                    ? message.content
                    : MarkerNeutralizer.escape(message.content)
                if !textHints.isEmpty {
                    textContent = MarkerNeutralizer.escape(textHints.joined(separator: " ")) + " " + textContent
                }
                if textContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    textContent = (hasDocuments || hasReferencedDocuments) ? "Please analyze this document." : "What's in this image?"
                }

                let rolePrefix = (message.role == .user) ? (dateHeader + timePrefix) : dateHeader
                textContent = rolePrefix + textContent
                contentParts.append(.text(textContent))

                apiMessages.append(OpenRouterAPIMessage(
                    role: role,
                    content: .parts(contentParts),
                    reasoning: historyReasoning,
                    reasoningDetails: historyReasoningDetails,
                    producedByModel: message.finalReasoningModel
                ))
            } else {
                // Standard text message. Internal per-turn metadata is injected
                // separately as a system note so the model does not mistake it
                // for prior assistant wording. Envelope-kind user messages
                // (email/subagent/bash/reminder) carry untrusted interiors —
                // neutralize the reserved harness marker; the human's own
                // typed text (.userText) stays byte-intact.
                var textContent = (message.role == .user && message.kind != .userText)
                    ? MarkerNeutralizer.escape(message.content)
                    : message.content

                // Add date header (if new day) and time prefix to text content
                // Only prefix user messages with the time. Prefixing assistant
                // messages causes the model to imitate the pattern and emit
                // "[HH:mm] ..." at the start of its own replies. Date header
                // still applies to both to mark day boundaries consistently.
                let rolePrefix = (message.role == .user) ? (dateHeader + timePrefix) : dateHeader
                textContent = rolePrefix + textContent
                apiMessages.append(OpenRouterAPIMessage(
                    role: role,
                    content: .text(textContent),
                    reasoning: historyReasoning,
                    reasoningDetails: historyReasoningDetails,
                    producedByModel: message.finalReasoningModel
                ))
            }

            if let metadataNote = await historyMetadataNote(for: message) {
                // Metadata notes interpolate untrusted-derived text (downloaded
                // filenames, model-written descriptions, prune summaries).
                apiMessages.append(OpenRouterAPIMessage(role: "system", content: .text(MarkerNeutralizer.escape(metadataNote))))
            }
        }

        // MARK: - Anthropic Prompt Caching
        // Anthropic models don't auto-cache like Gemini — they need explicit cache_control breakpoints.
        // We place breakpoints at (1) the system prompt and (2) the last conversation history message.
        // Everything from the start up to a breakpoint is cached as a prefix, so within a turn's
        // agentic tool loop these two regions are reused without re-processing.
        // For Gemini/other models this block is skipped — they either auto-cache or ignore cache_control.
        if context.anthropicCacheControl && apiMessages.count >= 1 {
            // Breakpoint 1: System prompt (index 0) — stable across the entire turn
            apiMessages[0] = apiMessages[0].withCacheControl()

            // Breakpoint 2: Last conversation history message — stable across tool loop rounds
            if apiMessages.count >= 2 {
                let lastHistoryIndex = apiMessages.count - 1
                apiMessages[lastHistoryIndex] = apiMessages[lastHistoryIndex].withCacheControl()
            }
        }

        // Add tool interactions if this is a follow-up call
        // IMPORTANT: Collect file attachments separately - OpenRouter doesn't support
        // multimodal content in tool role messages, so we inject files as a user message

        if let interactions = toolResultMessages {
            for interaction in interactions {
                // Add assistant's tool call message. producedByModel rides
                // along so the sanitize pass can compare provenance — without
                // it, a nil producer is "treated as same-model" and a
                // mid-turn model/provider change would replay this round's
                // reasoning natively against the wrong backend.
                apiMessages.append(OpenRouterAPIMessage(
                    role: "assistant",
                    content: interaction.assistantMessage.content.map { .text($0) },
                    toolCalls: interaction.assistantMessage.toolCalls,
                    reasoning: interaction.assistantMessage.reasoning,
                    reasoningDetails: interaction.assistantMessage.reasoningDetails,
                    producedByModel: interaction.assistantMessage.producedByModel
                ))

                var currentInteractionFiles: [FileAttachment] = []

                // Add tool results (text only - files will be added separately)
                for result in interaction.results {
                    // Collect file attachments for immediate injection after this round
                    if !result.fileAttachments.isEmpty {
                        print("[OpenRouterService] Collecting \(result.fileAttachments.count) file attachment(s) from tool result for user-role injection")
                        currentInteractionFiles.append(contentsOf: result.fileAttachments)
                    }

                    // Tool result is always text-only. Same single provider
                    // boundary as historical replay: neutralized content plus
                    // harness-rendered typed annotations — never raw
                    // `result.content` (MIDTURN_NONCE_PLAN §8 step 12).
                    apiMessages.append(OpenRouterAPIMessage(
                        role: "tool",
                        content: .text(try ProviderToolResultRenderer.wireText(for: result)),
                        toolCallId: result.toolCallId
                    ))
                }

                // Inject collected file attachments as a user message IMMEDIATELY following the tool results that produced them.
                // This ensures chronological order and prevents cache-busting from re-appending the same attachments at the end of every turn
                if !currentInteractionFiles.isEmpty {
                    print("[OpenRouterService] Injecting \(currentInteractionFiles.count) file attachment(s) as user-role multimodal message")
                    var contentParts: [ContentPart] = []

                    // Build descriptive text about the files
                    var visibleFiles: [String] = []
                    var nonInlineFiles: [String] = []
                    for attachment in currentInteractionFiles {
                        appendInlineAttachment(
                            filename: attachment.filename,
                            data: attachment.data,
                            mimeType: attachment.mimeType,
                            contentParts: &contentParts,
                            visibleFiles: &visibleFiles,
                            nonInlineFiles: &nonInlineFiles,
                            renderPDFAsImages: context.renderPDFAsImages
                        )
                    }

                    contentParts.append(.text(toolAttachmentText(visibleFiles: visibleFiles, nonInlineFiles: nonInlineFiles)))

                    apiMessages.append(OpenRouterAPIMessage(
                        role: "user",
                        content: .parts(contentParts)
                    ))
                }
            }
        }

        // Tail system message — used by force-finish paths to instruct the model
        // to stop calling tools and summarize, WITHOUT modifying the system prompt
        // or tool list. This preserves the prompt cache prefix for the entire
        // preceding context (system + messages + tool interactions).
        if let tail = tailSystemMessage, !tail.isEmpty {
            apiMessages.append(OpenRouterAPIMessage(
                role: "system",
                content: .text(tail)
            ))
        }

        // Temporary user-role maintenance request. Used for internal prompts
        // that need the model to produce visible text while staying out of
        // persisted chat history. Appended after cache breakpoints.
        if let tail = tailUserMessage, !tail.isEmpty {
            // Maintenance tails interpolate untrusted-derived text (prune
            // manifests with file paths); trusted wording never contains the
            // reserved marker, so escaping is a no-op for it.
            apiMessages.append(OpenRouterAPIMessage(
                role: "user",
                content: .text(MarkerNeutralizer.escape(tail))
            ))
        }

        // Ambient status tail — background bash + subagents currently running.
        // Appended AFTER the Anthropic cache breakpoint (placed above), so per-turn
        // drift in "running 12s / 35s / 1m 02s" does not invalidate any cached prefix.
        // Omitted entirely when nothing is running to avoid noise.
        var ambientLines: [String] = []
        if let bashLive = await BackgroundProcessRegistry.shared.liveSummaryText() {
            ambientLines.append(bashLive)
        }
        if let subagentLive = await SubagentBackgroundRegistry.shared.liveSummary() {
            ambientLines.append(subagentLive)
        }
        if !ambientLines.isEmpty {
            let ambientText = MarkerNeutralizer.escape("[Ambient status — not a user message]\n" + ambientLines.joined(separator: "\n"))
            apiMessages.append(OpenRouterAPIMessage(
                role: "user",
                content: .text(ambientText)
            ))
        }

        // Text-only model gate: replace all multimodal content with text
        // descriptions. The decision is keyed to the model that actually
        // serves THIS request: a per-run override (subagent cheap lane)
        // carries its own text-only semantics, so a cheap-text subagent under
        // a vision main model still gets OCR preprocessing, and a cheap-vision
        // subagent under a text-only main model keeps native images.
        if context.textOnly {
            try await preprocessMultimodalContent(in: &apiMessages)
        }

        let adapter = ChatCompletionsAdapter(context: context)
        let request = try adapter.makeRequest(messages: apiMessages, tools: conversation.tools)
        print("[OpenRouterService] Sending request to \(context.providerLabel) (\(context.model)) with \(apiMessages.count) messages")
        let (data, _) = try await sendChatRequestWithRetry(
            request, providerLabel: context.providerLabel, model: context.model
        )
        return try adapter.decodeResponse(data)
    }
}
