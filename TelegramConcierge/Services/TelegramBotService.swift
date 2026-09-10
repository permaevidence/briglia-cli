import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

actor TelegramBotService {
    /// Overridable for hermetic poller tests (a mock Bot API server).
    private let baseURL = ProcessInfo.processInfo.environment["BRIGLIA_TELEGRAM_API_BASE"]
        ?? "https://api.telegram.org/bot"
    private var botToken: String = ""

    // MARK: - Offset state (persisted)
    //
    // The poll offset and the time of the last real update survive restarts
    // in a small state file. Two reasons:
    // - Restart dedup: Telegram only confirms an update when a LATER
    //   getUpdates carries a higher offset. A restart right after processing
    //   (deterministic for /upgrade, which re-execs mid-update) used to make
    //   the new process start at offset 0 and receive the same update again.
    // - Reset detection: Telegram documents that after ≥1 week with no
    //   updates the next update_id is chosen randomly. A lower id is
    //   therefore a DUPLICATE when we heard from Telegram recently, and a
    //   sequence RESET when we haven't for a week — a time rule, not the
    //   distance heuristic this replaces (distance is undocumented and a
    //   close-below random id would have left the bot deaf).
    //
    // lastUpdateId is the last PROCESSED update, not the last fetched one:
    // getUpdates() returns a batch without advancing it, and the caller
    // confirms each update individually after it reaches durable state
    // (conversation history or the persisted mid-turn queue). Advancing per
    // batch at fetch time meant a crash — or /upgrade's exec-restart — after
    // the first update of a batch permanently skipped the rest.
    private var lastUpdateId: Int = 0
    private var lastUpdateAt: Date? = nil
    private var offsetStateLoaded = false
    /// Highest update id already handed to a caller this process lifetime —
    /// in-memory ONLY, never persisted. In the window between a fetch and its
    /// per-update confirms, lastUpdateId still points before the batch; a
    /// concurrent getUpdates (defense in depth against a second poll loop)
    /// consulting only lastUpdateId would be served the same updates again.
    /// A crash discards this mark, so unconfirmed updates still re-deliver
    /// to the next process — exactly the intended at-least-once behavior.
    private var fetchedThroughId: Int = 0

    private struct OffsetState: Codable {
        let lastUpdateId: Int
        let lastUpdateAt: Date?
        /// Fingerprint of the bot token the offsets belong to — a different
        /// bot has an unrelated id sequence, so inheriting another bot's
        /// high-water mark could silently drop all its messages. SHA-256
        /// prefix, never the token itself.
        let tokenHash: String?
    }

    private var currentTokenHash: String {
        let digest = SHA256.hash(data: Data(botToken.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    private var offsetStateURL: URL {
        StoragePaths.dataRoot.appendingPathComponent("telegram_offset.json")
    }

    private static let resetWindowSeconds: TimeInterval = {
        if let raw = ProcessInfo.processInfo.environment["BRIGLIA_TELEGRAM_RESET_WINDOW_SECONDS"],
           let value = TimeInterval(raw), value > 0 {
            return value  // test hook — production uses the documented week
        }
        return 7 * 24 * 3600
    }()

    private func loadOffsetStateIfNeeded() {
        guard !offsetStateLoaded else { return }
        offsetStateLoaded = true
        guard let data = try? Data(contentsOf: offsetStateURL),
              let state = try? JSONDecoder().decode(OffsetState.self, from: data) else { return }
        guard state.tokenHash == currentTokenHash else {
            print("[TelegramBotService] Stored offset state belongs to a different bot token — starting fresh")
            return
        }
        lastUpdateId = state.lastUpdateId
        lastUpdateAt = state.lastUpdateAt
    }

    /// Persist the current offset state to disk.
    func persistOffsetNow() {
        let state = OffsetState(lastUpdateId: lastUpdateId, lastUpdateAt: lastUpdateAt,
                                tokenHash: currentTokenHash)
        if let data = try? JSONEncoder().encode(state) {
            try? PrivateStorage.writeAtomically(data, to: offsetStateURL)
        }
    }

    /// Acknowledge ONE update as durably processed: advance the confirmed
    /// cursor to it and persist immediately. Must be called in delivery order
    /// (the poll loop processes a batch strictly sequentially, so it is) —
    /// the cursor is SET, not maxed, because after a week-of-silence sequence
    /// reset the legitimate new ids are LOWER than the old mark.
    /// A crash between processing update N and confirming it re-delivers N —
    /// at-least-once, the survivable direction. Updates after N in the same
    /// batch were never confirmed, so Telegram re-serves them too.
    func confirmProcessed(updateId: Int) {
        lastUpdateId = updateId
        lastUpdateAt = Date()
        persistOffsetNow()
    }

    func configure(token: String) {
        self.botToken = token
    }

    /// Point the service at a DIFFERENT bot (/switchbot cutover). The old
    /// bot's offset state is meaningless for the new one — update_id
    /// sequences are unrelated per bot, so inheriting the old high-water mark
    /// could silently drop every new-bot message (dedup would see "already
    /// processed" ids) — so both cursors reset and a fresh state file is
    /// persisted immediately under the new token's hash. The caller is
    /// responsible for having already advanced the NEW bot's server-side
    /// offset past its pre-switch messages (the discovery poll does).
    func adoptNewBot(token: String) {
        botToken = token
        lastUpdateId = 0
        fetchedThroughId = 0
        lastUpdateAt = nil
        offsetStateLoaded = true
        persistOffsetNow()
    }
    
    // MARK: - Error Handling Helper
    
    private func throwInvalidResponse(_ response: URLResponse?, data: Data) throws -> Never {
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(data: data, encoding: .utf8)
        throw TelegramError.invalidResponse(statusCode: statusCode, body: body)
    }

    /// Convert model-generated Markdown-like content into plain Telegram-friendly text.
    /// Telegram's parser does not support many common Markdown constructs (headings, **bold**, etc.),
    /// which can leak raw markers to end users.
    private func normalizeTelegramText(_ text: String) -> String {
        var normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // Normalize line-level structures first.
        let normalizedLines = normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { rawLine -> String in
                var line = String(rawLine)

                // Strip Markdown headings like "### Title".
                line = line.replacingRegexMatches(of: #"^\s{0,3}#{1,6}\s*"#, with: "")
                // Convert Markdown bullets into plain ASCII bullets.
                line = line.replacingRegexMatches(of: #"^\s*[-*+]\s+"#, with: "- ")
                // Remove blockquote markers.
                line = line.replacingRegexMatches(of: #"^\s*>\s?"#, with: "")

                // Remove code fence delimiter lines.
                if line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") {
                    return ""
                }

                return line
            }

        normalized = normalizedLines.joined(separator: "\n")

        // Convert common inline Markdown patterns to plain text.
        normalized = normalized.replacingOccurrences(of: "**", with: "")
        normalized = normalized.replacingOccurrences(of: "__", with: "")
        normalized = normalized.replacingOccurrences(of: "~~", with: "")
        normalized = normalized.replacingRegexMatches(of: #"`([^`\n]+)`"#, with: "$1")
        normalized = normalized.replacingRegexMatches(of: #"\*([^*\n]+)\*"#, with: "$1")
        normalized = normalized.replacingRegexMatches(of: #"_([^_\n]+)_"#, with: "$1")
        normalized = normalized.replacingRegexMatches(of: #"\[([^\]]+)\]\(([^)]+)\)"#, with: "$1 ($2)")

        // Keep spacing readable after cleanup.
        normalized = normalized.replacingRegexMatches(of: #"\n{3,}"#, with: "\n\n")
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Truncate a string so its UTF-16 representation fits within `limit` code units.
    private func truncateToUTF16Limit(_ text: String, limit: Int) -> String {
        guard text.utf16.count > limit else { return text }
        var used = 0
        var endIndex = text.startIndex
        for idx in text.indices {
            let charUTF16Len = text[idx].utf16.count
            if used + charUTF16Len > limit { break }
            used += charUTF16Len
            endIndex = text.index(after: idx)
        }
        return String(text[text.startIndex..<endIndex])
    }

    /// Test the bot token by calling getMe endpoint
    func getMe(token: String) async throws -> TelegramBotInfo {
        let url = URL(string: "\(baseURL)\(token)/getMe")!
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        
        let (data, response) = try await transportData(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            try throwInvalidResponse(response, data: data)
        }
        
        let decoded = try JSONDecoder().decode(TelegramResponse<TelegramBotInfo>.self, from: data)
        
        guard decoded.ok, let botInfo = decoded.result else {
            throw TelegramError.apiError(decoded.description ?? "Invalid token")
        }
        
        return botInfo
    }
    /// One entry per fetched update, in delivery order. `update` is nil for
    /// an undecodable update — nothing to process, but the caller must still
    /// confirm its id so the offset moves past it.
    struct PolledUpdate {
        let updateId: Int
        let update: TelegramUpdate?
    }

    func getUpdates() async throws -> [PolledUpdate] {
        guard !botToken.isEmpty else {
            throw TelegramError.notConfigured
        }
        loadOffsetStateIfNeeded()

        var urlComponents = URLComponents(string: "\(baseURL)\(botToken)/getUpdates")!
        urlComponents.queryItems = [
            URLQueryItem(name: "offset", value: String(max(lastUpdateId, fetchedThroughId) + 1)),
            URLQueryItem(name: "timeout", value: "0"),  // Instant return for 1-second polling
            // callback_query: inline-keyboard taps for the /provider, /model and
            // /effort menus (TelegramCommandMenu). Everything else stays out.
            URLQueryItem(name: "allowed_updates", value: "[\"message\",\"callback_query\"]")
        ]
        
        var request = URLRequest(url: urlComponents.url!)
        request.timeoutInterval = 10
        
        let (data, response) = try await transportData(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            try throwInvalidResponse(response, data: data)
        }
        
        // Decode updates INDIVIDUALLY (lossy). A whole-batch decode meant one
        // update our Codable models can't parse would throw before the offset
        // advanced — the same poison batch would be refetched forever and the
        // agent would go permanently deaf to everything after it. Now an
        // undecodable update is skipped, its update_id still advances the
        // offset, and a diagnostic is printed.
        let decoded = try JSONDecoder().decode(TelegramResponse<[LossyTelegramUpdate]>.self, from: data)

        guard decoded.ok, let lossyUpdates = decoded.result else {
            throw TelegramError.apiError(decoded.description ?? "Unknown error")
        }

        // Telegram's backend very occasionally re-delivers an update the
        // offset already confirmed (observed live 2026-08-04: the same
        // message dispatched twice ~1 min apart, producing a spurious
        // mid-turn "I'm still working" ack). update_ids increase
        // sequentially per bot, so an id at or below the high-water mark is a
        // duplicate — with ONE documented exception: after ≥1 week with no
        // updates, Telegram picks the next id randomly, possibly lower. The
        // discriminator is therefore TIME, not id distance: a below-the-mark
        // id is a duplicate when we heard from Telegram within the reset
        // window, and the start of a new sequence (adopt it, mark follows)
        // when we haven't.
        // The confirmed cursor (lastUpdateId) does NOT move here — only
        // confirmProcessed() advances it, one update at a time, after the
        // caller has put that update into durable state. dedupMark is a
        // batch-local shadow so in-batch duplicates still drop without
        // touching the confirmed cursor.
        var polled: [PolledUpdate] = []
        var dedupMark = max(lastUpdateId, fetchedThroughId)
        for lossy in lossyUpdates {
            guard let id = lossy.updateId else { continue }
            if id <= dedupMark {
                let recentActivity = lastUpdateAt.map {
                    Date().timeIntervalSince($0) < Self.resetWindowSeconds
                } ?? true  // mark without timestamp: legacy state, assume recent
                if recentActivity {
                    print("[TelegramBotService] Dropping re-delivered update \(id) (already processed up to \(dedupMark))")
                    continue
                }
                print("[TelegramBotService] update_id sequence reset detected (\(dedupMark) → \(id)) — adopting new sequence")
            }
            if lossy.update == nil {
                print("[TelegramBotService] Skipping undecodable update \(id) — advancing offset past it")
            }
            polled.append(PolledUpdate(updateId: id, update: lossy.update))
            dedupMark = id
        }
        fetchedThroughId = dedupMark
        return polled
    }

    /// Wrapper that never fails to decode: salvages the full update when
    /// possible, otherwise at least its update_id so the poll offset can move
    /// past a poison update instead of refetching it forever.
    /// (Codable, not just Decodable, because TelegramResponse's generic
    /// parameter is bound to Codable — encoding is never used in practice.)
    private struct LossyTelegramUpdate: Codable {
        let update: TelegramUpdate?
        let updateId: Int?

        private struct IdOnly: Codable {
            let updateId: Int
            enum CodingKeys: String, CodingKey { case updateId = "update_id" }
        }

        init(from decoder: Decoder) throws {
            if let full = try? TelegramUpdate(from: decoder) {
                update = full
                updateId = full.updateId
            } else {
                update = nil
                updateId = (try? IdOnly(from: decoder))?.updateId
            }
        }

        func encode(to encoder: Encoder) throws {
            try update?.encode(to: encoder)
        }
    }
    
    /// `keyboard` attaches an inline keyboard (command menus); nil sends a
    /// plain message with the request body unchanged from before keyboards
    /// existed.
    func sendMessage(chatId: Int, text: String, keyboard: TelegramInlineKeyboardMarkup? = nil) async throws {
        guard !botToken.isEmpty else {
            throw TelegramError.notConfigured
        }

        let url = URL(string: "\(baseURL)\(botToken)/sendMessage")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let cleanedText = normalizeTelegramText(text)
        let normalizedText = cleanedText.isEmpty ? text : cleanedText
        // Telegram enforces a 4096 UTF-16 code-unit limit per message.
        let finalText = truncateToUTF16Limit(normalizedText, limit: 4096)

        let body = TelegramSendMessageRequest(
            chatId: chatId,
            text: finalText,
            parseMode: nil,
            replyMarkup: keyboard
        )

        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await transportData(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            try throwInvalidResponse(response, data: data)
        }
        
        let decoded = try JSONDecoder().decode(TelegramResponse<TelegramMessage>.self, from: data)
        
        guard decoded.ok else {
            throw TelegramError.apiError(decoded.description ?? "Failed to send message")
        }
    }
    
    /// Registers the slash-command menu shown in Telegram (the "/" autocomplete
    /// and the blue Menu button). Command names must be lowercase a-z/0-9/_ and
    /// carry no leading slash here. This is cosmetic/discoverability only — the
    /// commands work whether or not they're registered — so callers should treat
    /// failures as non-fatal.
    func setMyCommands(_ commands: [(command: String, description: String)]) async throws {
        guard !botToken.isEmpty else {
            throw TelegramError.notConfigured
        }

        let url = URL(string: "\(baseURL)\(botToken)/setMyCommands")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = TelegramSetMyCommandsRequest(
            commands: commands.map { TelegramBotCommand(command: $0.command, description: $0.description) }
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await transportData(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            try throwInvalidResponse(response, data: data)
        }

        let decoded = try JSONDecoder().decode(TelegramResponse<Bool>.self, from: data)
        guard decoded.ok else {
            throw TelegramError.apiError(decoded.description ?? "Failed to set commands")
        }
    }

    func resetOffset() {
        lastUpdateId = 0
        fetchedThroughId = 0
    }

    // MARK: - Inline keyboard callbacks (command menus)

    /// Acknowledge a button tap. Telegram shows a spinner on the tapped
    /// button until the callback_query is answered (up to ~10 s), so every
    /// accepted tap is answered; `text` surfaces a short notice — as a
    /// toast, or as a modal alert with `showAlert` — without a chat message.
    func answerCallbackQuery(id: String, text: String? = nil, showAlert: Bool = false) async throws {
        try await postJSON(method: "answerCallbackQuery", body: TelegramAnswerCallbackQueryRequest(
            callbackQueryId: id, text: text, showAlert: showAlert ? true : nil))
    }

    /// Replace a message's text. No reply_markup in the request means the
    /// message's inline keyboard is removed — how a menu is frozen after a
    /// tap so its buttons can't fire twice.
    func editMessageText(chatId: Int, messageId: Int, text: String) async throws {
        let cleaned = normalizeTelegramText(text)
        let finalText = truncateToUTF16Limit(cleaned.isEmpty ? text : cleaned, limit: 4096)
        try await postJSON(method: "editMessageText", body: TelegramEditMessageTextRequest(
            chatId: chatId, messageId: messageId, text: finalText))
    }

    private struct TelegramOkEnvelope: Decodable {
        let ok: Bool
        let description: String?
    }

    /// POST a JSON body to a Bot API method whose result we don't need —
    /// only the ok flag is checked (the result type differs per method).
    private func postJSON<Body: Encodable>(method: String, body: Body) async throws {
        guard !botToken.isEmpty else {
            throw TelegramError.notConfigured
        }
        let url = URL(string: "\(baseURL)\(botToken)/\(method)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await transportData(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            try throwInvalidResponse(response, data: data)
        }
        let decoded = try JSONDecoder().decode(TelegramOkEnvelope.self, from: data)
        guard decoded.ok else {
            throw TelegramError.apiError(decoded.description ?? "\(method) failed")
        }
    }
    
    // MARK: - Voice File Download
    
    func getFile(fileId: String) async throws -> TelegramFile {
        guard !botToken.isEmpty else {
            throw TelegramError.notConfigured
        }
        
        var urlComponents = URLComponents(string: "\(baseURL)\(botToken)/getFile")!
        urlComponents.queryItems = [
            URLQueryItem(name: "file_id", value: fileId)
        ]
        
        var request = URLRequest(url: urlComponents.url!)
        request.timeoutInterval = 30
        
        let (data, response) = try await transportData(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            try throwInvalidResponse(response, data: data)
        }
        
        let decoded = try JSONDecoder().decode(TelegramResponse<TelegramFile>.self, from: data)
        
        guard decoded.ok, let file = decoded.result else {
            throw TelegramError.apiError(decoded.description ?? "Failed to get file info")
        }
        
        return file
    }
    
    func downloadVoiceFile(fileId: String) async throws -> URL {
        let file = try await getFile(fileId: fileId)
        
        guard let filePath = file.filePath else {
            throw TelegramError.apiError("No file path returned from Telegram")
        }
        
        // Build the download URL
        let downloadURLString = "https://api.telegram.org/file/bot\(botToken)/\(filePath)"
        guard let downloadURL = URL(string: downloadURLString) else {
            throw TelegramError.apiError("Invalid download URL")
        }
        
        var request = URLRequest(url: downloadURL)
        request.timeoutInterval = 60
        
        let (data, response) = try await transportData(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            try throwInvalidResponse(response, data: data)
        }
        
        // Save to temporary file
        let tempDir = FileManager.default.temporaryDirectory
        let localURL = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension("ogg")
        try data.write(to: localURL)
        
        return localURL
    }
    
    func downloadPhoto(fileId: String) async throws -> Data {
        let file = try await getFile(fileId: fileId)
        
        guard let filePath = file.filePath else {
            throw TelegramError.apiError("No file path returned from Telegram")
        }
        
        // Build the download URL
        let downloadURLString = "https://api.telegram.org/file/bot\(botToken)/\(filePath)"
        guard let downloadURL = URL(string: downloadURLString) else {
            throw TelegramError.apiError("Invalid download URL")
        }
        
        var request = URLRequest(url: downloadURL)
        request.timeoutInterval = 60
        
        let (data, response) = try await transportData(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            try throwInvalidResponse(response, data: data)
        }
        
        return data
    }
    
    /// Download a document (any file type) from Telegram
    func downloadDocument(fileId: String) async throws -> Data {
        let file = try await getFile(fileId: fileId)
        
        guard let filePath = file.filePath else {
            throw TelegramError.apiError("No file path returned from Telegram")
        }
        
        // Build the download URL
        let downloadURLString = "https://api.telegram.org/file/bot\(botToken)/\(filePath)"
        guard let downloadURL = URL(string: downloadURLString) else {
            throw TelegramError.apiError("Invalid download URL")
        }
        
        var request = URLRequest(url: downloadURL)
        request.timeoutInterval = 120  // Longer timeout for larger files
        
        let (data, response) = try await transportData(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            try throwInvalidResponse(response, data: data)
        }
        
        return data
    }
    
    // MARK: - Send Photo
    
    /// Send a photo to a chat
    func sendPhoto(chatId: Int, imageData: Data, caption: String? = nil, mimeType: String = "image/png") async throws {
        guard !botToken.isEmpty else {
            throw TelegramError.notConfigured
        }
        
        let url = URL(string: "\(baseURL)\(botToken)/sendPhoto")!
        
        // Create multipart form data
        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        
        var body = Data()
        
        // Add chat_id field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(chatId)\r\n".data(using: .utf8)!)
        
        // Add photo file
        let fileExtension = mimeType.contains("jpeg") || mimeType.contains("jpg") ? "jpg" : "png"
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"photo\"; filename=\"image.\(fileExtension)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n".data(using: .utf8)!)
        
        // Add caption if provided
        if let caption = caption {
            let safeCaption = normalizeTelegramText(caption)
            if !safeCaption.isEmpty {
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                body.append("Content-Disposition: form-data; name=\"caption\"\r\n\r\n".data(using: .utf8)!)
                body.append("\(safeCaption)\r\n".data(using: .utf8)!)
            }
        }
        
        // End boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        request.httpBody = body
        
        let (data, response) = try await transportData(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            try throwInvalidResponse(response, data: data)
        }
        
        let decoded = try JSONDecoder().decode(TelegramResponse<TelegramMessage>.self, from: data)
        
        guard decoded.ok else {
            throw TelegramError.apiError(decoded.description ?? "Failed to send photo")
        }
    }
    
    // MARK: - Send Document
    
    /// Send a document/file to a chat
    func sendDocument(chatId: Int, documentData: Data, filename: String, caption: String? = nil, mimeType: String = "application/octet-stream") async throws {
        guard !botToken.isEmpty else {
            throw TelegramError.notConfigured
        }
        
        let url = URL(string: "\(baseURL)\(botToken)/sendDocument")!
        
        // Create multipart form data
        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120  // Longer timeout for larger files
        
        var body = Data()
        
        // Add chat_id field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(chatId)\r\n".data(using: .utf8)!)
        
        // Add document file
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"document\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(documentData)
        body.append("\r\n".data(using: .utf8)!)
        
        // Add caption if provided
        if let caption = caption {
            let safeCaption = normalizeTelegramText(caption)
            if !safeCaption.isEmpty {
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                body.append("Content-Disposition: form-data; name=\"caption\"\r\n\r\n".data(using: .utf8)!)
                body.append("\(safeCaption)\r\n".data(using: .utf8)!)
            }
        }
        
        // End boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        request.httpBody = body
        
        let (data, response) = try await transportData(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            try throwInvalidResponse(response, data: data)
        }
        
        let decoded = try JSONDecoder().decode(TelegramResponse<TelegramMessage>.self, from: data)
        
        guard decoded.ok else {
            throw TelegramError.apiError(decoded.description ?? "Failed to send document")
        }
    }

    // MARK: - Transport

    /// Every Bot API request goes through here so a transport failure can
    /// never carry the request URL — and with it the bot token — out of this
    /// actor. NSURLError's userInfo embeds NSErrorFailingURLStringKey
    /// verbatim, and `"\(error)"` renderings (poll-tick diagnostics, the
    /// error-reply log line) print userInfo in full: a DNS outage printed
    /// `https://api.telegram.org/bot<token>/getUpdates?...` to the terminal.
    /// The rethrown error keeps only the URLError code and the localized
    /// description (token-scrubbed as a belt-and-braces measure). Cancellation
    /// is preserved as a bare `URLError(.cancelled)` so the caller's
    /// cancellation predicate still recognises it.
    private func transportData(for request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch let urlError as URLError {
            if urlError.code == .cancelled { throw URLError(.cancelled) }
            throw TelegramError.transport(code: urlError.code.rawValue,
                                          description: scrubToken(urlError.localizedDescription))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let nsError = error as NSError
            throw TelegramError.transport(code: nsError.code,
                                          description: scrubToken(error.localizedDescription))
        }
    }

    private func scrubToken(_ text: String) -> String {
        var out = text
        if !botToken.isEmpty { out = out.replacingOccurrences(of: botToken, with: "[REDACTED]") }
        return TelegramBotService.redactBotTokens(in: out)
    }

    /// Replace anything shaped like a Bot API token (`bot<id>:<secret>` or a
    /// bare `<id>:<secret>`) in free text. Used for the transport error path
    /// and available to log sites that render foreign errors.
    static func redactBotTokens(in text: String) -> String {
        text.replacingRegexMatches(of: #"(?<![A-Za-z0-9_-])(bot)?[0-9]{6,}:[A-Za-z0-9_-]{25,}"#,
                                   with: "$1[REDACTED]")
    }
}

private extension String {
    func replacingRegexMatches(of pattern: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return self
        }
        let range = NSRange(startIndex..<endIndex, in: self)
        return regex.stringByReplacingMatches(in: self, options: [], range: range, withTemplate: replacement)
    }
}

enum TelegramError: LocalizedError, CustomStringConvertible {
    case notConfigured
    case invalidResponse(statusCode: Int, body: String?)
    case apiError(String)
    /// URLSession failure with the URL (and token) deliberately dropped.
    case transport(code: Int, description: String)
    
    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Telegram bot is not configured"
        case .invalidResponse(let statusCode, let body):
            if let body = body, !body.isEmpty {
                return "Telegram API error (HTTP \(statusCode)): \(body.prefix(200))"
            }
            return "Telegram API error (HTTP \(statusCode))"
        case .apiError(let message):
            return "Telegram API error: \(message)"
        case .transport(let code, let description):
            return "Telegram network error (\(code)): \(description)"
        }
    }

    var description: String { errorDescription ?? "Telegram error" }
}
