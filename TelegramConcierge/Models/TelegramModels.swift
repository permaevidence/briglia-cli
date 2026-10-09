import Foundation

// MARK: - Telegram Bot API Response Models

struct TelegramResponse<T: Codable>: Codable {
    let ok: Bool
    let result: T?
    let description: String?
}

struct TelegramUpdate: Codable, Identifiable {
    let updateId: Int
    let message: TelegramMessage?
    /// An inline-keyboard tap (command menus). Delivered only because
    /// getUpdates asks for it in allowed_updates; nil for message updates.
    let callbackQuery: TelegramCallbackQuery?
    
    var id: Int { updateId }
    
    enum CodingKeys: String, CodingKey {
        case updateId = "update_id"
        case message
        case callbackQuery = "callback_query"
    }
}

// MARK: - Inline keyboards (command menus)

/// A tap on an inline button. `message` is the menu message the keyboard was
/// attached to (Bot API ≥ 7 may send an "inaccessible message" carrying only
/// chat + message_id + date 0, which decodes fine here); `data` is the
/// button's callback_data, ≤ 64 bytes.
struct TelegramCallbackQuery: Codable {
    let id: String
    let from: TelegramUser
    let message: TelegramMessage?
    let data: String?
}

struct TelegramInlineKeyboardButton: Codable, Equatable {
    let text: String
    let callbackData: String

    enum CodingKeys: String, CodingKey {
        case text
        case callbackData = "callback_data"
    }
}

struct TelegramInlineKeyboardMarkup: Codable, Equatable {
    let inlineKeyboard: [[TelegramInlineKeyboardButton]]

    enum CodingKeys: String, CodingKey {
        case inlineKeyboard = "inline_keyboard"
    }
}

struct TelegramAnswerCallbackQueryRequest: Codable {
    let callbackQueryId: String
    let text: String?
    let showAlert: Bool?

    enum CodingKeys: String, CodingKey {
        case callbackQueryId = "callback_query_id"
        case text
        case showAlert = "show_alert"
    }
}

/// editMessageText without reply_markup: the new text replaces the old and
/// the inline keyboard is removed.
struct TelegramEditMessageTextRequest: Codable {
    let chatId: Int
    let messageId: Int
    let text: String

    enum CodingKeys: String, CodingKey {
        case chatId = "chat_id"
        case messageId = "message_id"
        case text
    }
}

// Box wrapper for recursive Codable types (Swift structs cannot contain themselves)
final class Box<T: Codable>: Codable {
    let value: T
    init(_ value: T) { self.value = value }
    
    required init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.value = try container.decode(T.self)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// Decoding outcome of an optional message field that must never make the
/// whole update undecodable (CACHE_KEY_AND_IMAGE_REJECTION_PLAN v2 §3.3):
/// absent, decoded, or present but not decodable.
enum TelegramFieldState: Equatable {
    case absent
    case decoded
    case presentUndecodable
}

struct TelegramMessage: Codable {
    let messageId: Int
    let from: TelegramUser?
    let chat: TelegramChat
    let date: Int
    let text: String?
    let voice: TelegramVoice?
    let video: TelegramVideo?
    let photo: [TelegramPhotoSize]?
    let document: TelegramDocument?
    let caption: String?
    private let _replyToMessage: Box<TelegramMessage>?  // Boxed to avoid infinite struct size
    
    // Forwarded message fields (Telegram API 7.0+)
    let forwardOrigin: TelegramMessageOrigin?
    // Legacy forwarding fields (pre-7.0, deprecated but still sent by Telegram)
    let forwardFrom: TelegramUser?
    let forwardFromChat: TelegramChat?
    let forwardDate: Int?

    /// Audio files (an .m4a/.mp3 sent from Files arrives as `audio`, not
    /// `voice`) and round video notes. Decoded leniently: a malformed value
    /// is recorded as `presentUndecodable` and the rest of the message
    /// (text, caption, other fields) still decodes.
    let audio: TelegramAudio?
    let videoNote: TelegramVideoNote?
    let audioState: TelegramFieldState
    let videoNoteState: TelegramFieldState
    /// Album identifier (several messages sent together), lenient.
    let mediaGroupId: String?
    /// Allowlisted user-content kinds Briglia cannot read yet, detected by
    /// key presence only (never decoding arbitrary JSON). Service events are
    /// deliberately not in the list.
    let unreadableKinds: [String]
    
    /// The message being replied to/cited
    var replyToMessage: TelegramMessage? { _replyToMessage?.value }
    
    /// Check if this message is forwarded
    var isForwarded: Bool {
        forwardOrigin != nil || forwardFrom != nil || forwardFromChat != nil
    }
    
    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case from
        case chat
        case date
        case text
        case voice
        case video
        case photo
        case document
        case caption
        case _replyToMessage = "reply_to_message"
        case forwardOrigin = "forward_origin"
        case forwardFrom = "forward_from"
        case forwardFromChat = "forward_from_chat"
        case forwardDate = "forward_date"
        case audio
        case videoNote = "video_note"
        case mediaGroupId = "media_group_id"
    }

    /// User-content kinds that get one visible "can't read this yet" reply
    /// when nothing else in the update could be used. Not exhaustive by
    /// design (unknown keys stay silent); `animation` is excluded because
    /// Telegram also sends it as `document`; service events (pinned_message,
    /// giveaway_created/completed, checklist task events, chat membership,
    /// write access, auto-delete changes) never qualify.
    enum UnreadableKind: String, CodingKey, CaseIterable {
        case sticker, location, venue, contact, poll, dice, game, story
        case paidMedia = "paid_media"
        case invoice, giveaway
        case giveawayWinners = "giveaway_winners"
        case checklist
        case livePhoto = "live_photo"

        var displayName: String {
            switch self {
            case .paidMedia: return "paid media"
            case .giveawayWinners: return "giveaway result"
            case .livePhoto: return "live photo"
            default: return rawValue
            }
        }
    }

    /// Existing fields decode exactly as the synthesized decoder did; only
    /// the new fields are lenient.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messageId = try c.decode(Int.self, forKey: .messageId)
        from = try c.decodeIfPresent(TelegramUser.self, forKey: .from)
        chat = try c.decode(TelegramChat.self, forKey: .chat)
        date = try c.decode(Int.self, forKey: .date)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        voice = try c.decodeIfPresent(TelegramVoice.self, forKey: .voice)
        video = try c.decodeIfPresent(TelegramVideo.self, forKey: .video)
        photo = try c.decodeIfPresent([TelegramPhotoSize].self, forKey: .photo)
        document = try c.decodeIfPresent(TelegramDocument.self, forKey: .document)
        caption = try c.decodeIfPresent(String.self, forKey: .caption)
        _replyToMessage = try c.decodeIfPresent(Box<TelegramMessage>.self, forKey: ._replyToMessage)
        forwardOrigin = try c.decodeIfPresent(TelegramMessageOrigin.self, forKey: .forwardOrigin)
        forwardFrom = try c.decodeIfPresent(TelegramUser.self, forKey: .forwardFrom)
        forwardFromChat = try c.decodeIfPresent(TelegramChat.self, forKey: .forwardFromChat)
        forwardDate = try c.decodeIfPresent(Int.self, forKey: .forwardDate)
        (audio, audioState) = Self.lenient(TelegramAudio.self, c, .audio)
        (videoNote, videoNoteState) = Self.lenient(TelegramVideoNote.self, c, .videoNote)
        mediaGroupId = (try? c.decodeIfPresent(String.self, forKey: .mediaGroupId)) ?? nil
        let probe = try? decoder.container(keyedBy: UnreadableKind.self)
        unreadableKinds = UnreadableKind.allCases.filter { probe?.contains($0) == true }.map(\.rawValue)
    }

    private static func lenient<T: Decodable>(_ type: T.Type, _ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys)
        -> (T?, TelegramFieldState) {
        guard c.contains(key) else { return (nil, .absent) }
        if (try? c.decodeNil(forKey: key)) == true { return (nil, .absent) }
        if let value = try? c.decode(T.self, forKey: key) { return (value, .decoded) }
        return (nil, .presentUndecodable)
    }
}

struct TelegramAudio: Codable {
    let fileId: String
    let fileUniqueId: String
    let duration: Int
    let performer: String?
    let title: String?
    let fileName: String?
    let mimeType: String?
    let fileSize: Int?

    enum CodingKeys: String, CodingKey {
        case fileId = "file_id"
        case fileUniqueId = "file_unique_id"
        case duration, performer, title
        case fileName = "file_name"
        case mimeType = "mime_type"
        case fileSize = "file_size"
    }
}

struct TelegramVideoNote: Codable {
    let fileId: String
    let fileUniqueId: String
    let length: Int
    let duration: Int
    let fileSize: Int?

    enum CodingKeys: String, CodingKey {
        case fileId = "file_id"
        case fileUniqueId = "file_unique_id"
        case length, duration
        case fileSize = "file_size"
    }
}

// MARK: - Forwarded Message Origin (Telegram API 7.0+)

/// Describes the origin of a forwarded message
struct TelegramMessageOrigin: Codable {
    let type: String  // "user", "hidden_user", "chat", "channel"
    let date: Int
    
    // For type "user"
    let senderUser: TelegramUser?
    
    // For type "hidden_user"
    let senderUserName: String?
    
    // For type "chat" or "channel"
    let senderChat: TelegramChat?
    let authorSignature: String?
    
    // For type "channel"
    let messageId: Int?
    
    enum CodingKeys: String, CodingKey {
        case type
        case date
        case senderUser = "sender_user"
        case senderUserName = "sender_user_name"
        case senderChat = "sender_chat"
        case authorSignature = "author_signature"
        case messageId = "message_id"
    }
    
    /// Get a human-readable description of the forward origin
    var description: String {
        switch type {
        case "user":
            if let user = senderUser {
                let name = [user.firstName, user.lastName].compactMap { $0 }.joined(separator: " ")
                return name.isEmpty ? "a user" : name
            }
            return "a user"
        case "hidden_user":
            return senderUserName ?? "a hidden user"
        case "chat":
            return senderChat?.title ?? "a chat"
        case "channel":
            return senderChat?.title ?? "a channel"
        default:
            return "unknown source"
        }
    }
}

struct TelegramDocument: Codable {
    let fileId: String
    let fileUniqueId: String
    let fileName: String?
    let mimeType: String?
    let fileSize: Int?
    
    enum CodingKeys: String, CodingKey {
        case fileId = "file_id"
        case fileUniqueId = "file_unique_id"
        case fileName = "file_name"
        case mimeType = "mime_type"
        case fileSize = "file_size"
    }
}

struct TelegramPhotoSize: Codable {
    let fileId: String
    let fileUniqueId: String
    let width: Int
    let height: Int
    let fileSize: Int?
    
    enum CodingKeys: String, CodingKey {
        case fileId = "file_id"
        case fileUniqueId = "file_unique_id"
        case width
        case height
        case fileSize = "file_size"
    }
}

struct TelegramVoice: Codable {
    let fileId: String
    let fileUniqueId: String
    let duration: Int
    let mimeType: String?
    let fileSize: Int?
    
    enum CodingKeys: String, CodingKey {
        case fileId = "file_id"
        case fileUniqueId = "file_unique_id"
        case duration
        case mimeType = "mime_type"
        case fileSize = "file_size"
    }
}

struct TelegramVideo: Codable {
    let fileId: String
    let fileUniqueId: String
    let width: Int
    let height: Int
    let duration: Int
    let thumbnail: TelegramPhotoSize?
    let fileName: String?
    let mimeType: String?
    let fileSize: Int?
    
    enum CodingKeys: String, CodingKey {
        case fileId = "file_id"
        case fileUniqueId = "file_unique_id"
        case width
        case height
        case duration
        case thumbnail = "thumbnail"
        case fileName = "file_name"
        case mimeType = "mime_type"
        case fileSize = "file_size"
    }
}

struct TelegramFile: Codable {
    let fileId: String
    let fileUniqueId: String
    let fileSize: Int?
    let filePath: String?
    
    enum CodingKeys: String, CodingKey {
        case fileId = "file_id"
        case fileUniqueId = "file_unique_id"
        case fileSize = "file_size"
        case filePath = "file_path"
    }
}

struct TelegramUser: Codable {
    let id: Int
    let isBot: Bool
    let firstName: String
    let lastName: String?
    let username: String?
    
    enum CodingKeys: String, CodingKey {
        case id
        case isBot = "is_bot"
        case firstName = "first_name"
        case lastName = "last_name"
        case username
    }
}

struct TelegramChat: Codable {
    let id: Int
    let type: String
    let title: String?
    let username: String?
    let firstName: String?
    let lastName: String?
    
    enum CodingKeys: String, CodingKey {
        case id
        case type
        case title
        case username
        case firstName = "first_name"
        case lastName = "last_name"
    }
}

struct TelegramBotInfo: Codable {
    let id: Int
    let isBot: Bool
    let firstName: String
    let username: String?
    
    enum CodingKeys: String, CodingKey {
        case id
        case isBot = "is_bot"
        case firstName = "first_name"
        case username
    }
}

struct TelegramSendMessageRequest: Codable {
    let chatId: Int
    let text: String
    let parseMode: String?
    /// Optional inline keyboard (command menus). nil is omitted from the
    /// JSON, so plain sends encode exactly as before.
    let replyMarkup: TelegramInlineKeyboardMarkup?

    enum CodingKeys: String, CodingKey {
        case chatId = "chat_id"
        case text
        case parseMode = "parse_mode"
        case replyMarkup = "reply_markup"
    }
}

struct TelegramBotCommand: Codable {
    let command: String
    let description: String
}

struct TelegramSetMyCommandsRequest: Codable {
    let commands: [TelegramBotCommand]
}
