import Foundation

/// Which messaging transport a conversation message travelled over.
enum ChannelKind: String, Codable, CaseIterable {
    case telegram
    case whatsapp
    /// The app's own chat window. The conversation history IS the UI, so this
    /// transport has no wire: text replies need no delivery, and media sends
    /// are persisted + appended to history by ConversationManager callbacks.
    case app

    var displayName: String {
        switch self {
        case .telegram: return "Telegram"
        case .whatsapp: return "WhatsApp"
        case .app: return "App"
        }
    }
}

/// A fully-qualified destination for outbound messages: the transport plus the
/// transport-native chat identifier (Telegram numeric chat id as a string,
/// WhatsApp JID like "39333...@s.whatsapp.net").
struct ChannelAddress: Codable, Equatable, Hashable {
    let kind: ChannelKind
    let chatId: String
}

/// Outbound surface every messaging transport must provide. Inbound delivery is
/// transport-specific (Telegram long-polls, WhatsApp pushes from a sidecar), so
/// only the send side is abstracted; ConversationManager routes each turn's
/// output to the channel its triggering message arrived on.
protocol ChatChannel: Sendable {
    var kind: ChannelKind { get }
    func sendText(chatId: String, text: String) async throws
    func sendPhoto(chatId: String, imageData: Data, caption: String?, mimeType: String) async throws
    func sendDocument(chatId: String, documentData: Data, filename: String, caption: String?, mimeType: String) async throws
}

// MARK: - In-app conformance

/// Transport for turns started from the app's own chat composer. Turn replies
/// and error notices already land in conversation history — which the window
/// displays — so `sendText` is deliberately a no-op. Photos and documents the
/// agent explicitly sends (send_document_to_chat) are handed
/// to ConversationManager, which persists them and appends a visible message.
struct AppLocalChannel: ChatChannel {
    nonisolated var kind: ChannelKind { .app }

    let onPhoto: @Sendable (Data, String?, String) async -> Void
    let onDocument: @Sendable (Data, String, String?, String) async -> Void

    func sendText(chatId: String, text: String) async throws {
        // No-op: the chat view renders history directly.
    }

    func sendPhoto(chatId: String, imageData: Data, caption: String?, mimeType: String) async throws {
        await onPhoto(imageData, caption, mimeType)
    }

    func sendDocument(chatId: String, documentData: Data, filename: String, caption: String?, mimeType: String) async throws {
        await onDocument(documentData, filename, caption, mimeType)
    }
}

// MARK: - Telegram conformance

extension TelegramBotService: ChatChannel {
    nonisolated var kind: ChannelKind { .telegram }

    func sendText(chatId: String, text: String) async throws {
        guard let numericId = Int(chatId) else {
            throw TelegramError.apiError("Invalid Telegram chat id: \(chatId)")
        }
        try await sendMessage(chatId: numericId, text: text)
    }

    func sendPhoto(chatId: String, imageData: Data, caption: String?, mimeType: String) async throws {
        guard let numericId = Int(chatId) else {
            throw TelegramError.apiError("Invalid Telegram chat id: \(chatId)")
        }
        try await sendPhoto(chatId: numericId, imageData: imageData, caption: caption, mimeType: mimeType)
    }

    func sendDocument(chatId: String, documentData: Data, filename: String, caption: String?, mimeType: String) async throws {
        guard let numericId = Int(chatId) else {
            throw TelegramError.apiError("Invalid Telegram chat id: \(chatId)")
        }
        try await sendDocument(chatId: numericId, documentData: documentData, filename: filename, caption: caption, mimeType: mimeType)
    }
}
