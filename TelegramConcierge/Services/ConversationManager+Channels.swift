import Foundation
#if canImport(Combine)
import Combine
#else
import OpenCombine
import OpenCombineDispatch
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
extension ConversationManager {

    /// Selftest-only visibility: the current ambient destination's kind.
    /// Pins the contract that app/terminal commands never redirect ambient
    /// output (reminders, alerts) away from the user's messaging channel.
    var ambientChannelKindForTesting: String? { lastUserChannelAddress?.kind.rawValue }

    var telegramAddress: ChannelAddress? {
        pairedChatId.map { ChannelAddress(kind: .telegram, chatId: String($0)) }
    }

    /// Destination for output not tied to a specific turn. Inside an open
    /// command-capture window the app channel is returned so command handlers
    /// work (and their `replyAddress != nil` guards pass) even on a setup with
    /// no messaging channel configured — those sends are then captured, never
    /// wired.
    var replyAddress: ChannelAddress? {
        if Self.commandCapture?.isOpen == true { return Self.appChannelAddress }
        return lastUserChannelAddress ?? telegramAddress
    }

    func noteUserActivity(on address: ChannelAddress) {
        guard lastUserChannelAddress != address else { return }
        lastUserChannelAddress = address
        if let data = try? JSONEncoder().encode(address) {
            Prefs.store.set(data, forKey: lastUserChannelDefaultsKey)
        }
    }

    func loadLastUserChannelAddress() {
        guard let data = Prefs.store.data(forKey: lastUserChannelDefaultsKey),
              let address = try? JSONDecoder().decode(ChannelAddress.self, from: data) else { return }
        lastUserChannelAddress = address
    }

    /// Send text to an explicit address, or to `replyAddress` when nil.
    /// Silently no-ops when no destination is configured — mirroring the old
    /// `if let chatId = pairedChatId` guards.
    ///
    /// Bounded retry (3 attempts) rides out transient network blips. On final
    /// failure the message is PARKED and re-attempted on the next successful
    /// poll tick or send — previously a single failed attempt lost the reply
    /// silently (it survived in history, but the user experienced being
    /// ignored). Still throws on failure so callers can react.
    func sendText(_ text: String, to address: ChannelAddress? = nil) async throws {
        // Local command window: collect command responses for the REPL/app to
        // render instead of sending them over a wire (the .app channel has
        // none). Only replies destined for the command surface are captured —
        // an explicit Telegram-addressed send inside a handler still
        // goes out for real, and a closed capture (straggler task) falls
        // through to normal delivery.
        if let capture = Self.commandCapture,
           address == nil || address?.kind == .app,
           capture.append(text) {
            return
        }
        guard let address = address ?? replyAddress,
              let channel = channels[address.kind] else { return }
        var lastError: Error? = nil
        for attempt in 1...3 {
            do {
                try await channel.sendText(chatId: address.chatId, text: text)
                await flushParkedOutbound()
                return
            } catch {
                lastError = error
                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: UInt64(2 * attempt) * 1_000_000_000)
                }
            }
        }
        parkOutbound(text, address: address)
        throw lastError ?? URLError(.cannotConnectToHost)
    }

    private func parkOutbound(_ text: String, address: ChannelAddress) {
        let queued = parkedOutbound.park(text, address: address)
        print("[ConversationManager] Parked undeliverable reply (\(queued) queued) — will retry when the channel recovers")
    }

    /// Re-attempt parked replies in order; stops at the first failure so a
    /// still-broken channel isn't hammered. Called from the poll loop's
    /// success path and after any successful send; a flush already in
    /// progress makes this a no-op (the running flush drains new items too).
    func flushParkedOutbound() async {
        await parkedOutbound.flush(
            deliver: { [weak self] item in
                guard let self, let channel = self.channels[item.address.kind] else { return false }
                try await channel.sendText(chatId: item.address.chatId, text: item.text)
                return true
            },
            onDelivered: { _, left in
                print("[ConversationManager] Delivered parked reply (\(left) left)")
            }
        )
    }

    /// Immediate delivery for the mid_turn_message_user tool. The message is
    /// appended to conversation history FIRST — same order as final replies —
    /// so it persists through pruning/archiving (the compact tool log drops
    /// call arguments) and backs the in-memory park queue's durability
    /// assumption if the wire send fails. The REPL and app window render new
    /// history messages, so the append IS the delivery for terminal/app-origin
    /// turns; wire channels (Telegram) additionally get a real send
    /// with the standard retry/park behavior. Answers route to the channel the
    /// latest mid-turn user message arrived on when there is one; progress
    /// updates fall back to the turn's origin. Throws when the turn is no
    /// longer active so the tool reports failure instead of messaging the
    /// user from a superseded turn.
    func deliverAgentMidTurnMessage(_ text: String, for runId: UUID, to address: ChannelAddress?) async throws {
        guard activeRunId == runId else {
            throw NSError(domain: "Briglia", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "the turn is no longer active"
            ])
        }
        messages.append(Message(role: .assistant, content: text))
        saveConversation()
        let target = lastMidTurnUserAddress ?? address
        if let target, target.kind != .app, channels[target.kind] != nil {
            try await sendText(text, to: target)
        }
    }

    /// End-of-turn delivery of what send_document_to_chat queued (an image
    /// file goes as a photo, anything else as a document). This is the only
    /// automatic media send: generate_image queues nothing, so a generated
    /// image reaches the user only through an explicit send_document_to_chat.
    /// Returns false when the turn was superseded mid-delivery.
    static func deliverQueuedTurnMedia(
        stillCurrent: () -> Bool,
        sendPhoto: (Data, String?, String) async throws -> Void,
        sendDocument: (Data, String, String?, String) async throws -> Void
    ) async throws -> Bool {
        for (documentData, filename, mimeType, caption) in ToolExecutor.getPendingDocuments() {
            try Task.checkCancellation()
            guard stillCurrent() else { return false }
            do {
                if mimeType.hasPrefix("image/") {
                    try await sendPhoto(documentData, caption, mimeType)
                    print("[ConversationManager] Sent image as photo: \(filename) (\(documentData.count) bytes)")
                } else {
                    try await sendDocument(documentData, filename, caption, mimeType)
                    print("[ConversationManager] Sent document: \(filename) (\(documentData.count) bytes)")
                }
            } catch {
                print("[ConversationManager] Failed to send document \(filename): \(error)")
            }
        }
        return true
    }

    func sendPhoto(_ imageData: Data, caption: String?, mimeType: String, to address: ChannelAddress? = nil) async throws {
        guard let address = address ?? replyAddress,
              let channel = channels[address.kind] else { return }
        try await channel.sendPhoto(chatId: address.chatId, imageData: imageData, caption: caption, mimeType: mimeType)
    }

    func sendDocument(_ documentData: Data, filename: String, caption: String?, mimeType: String, to address: ChannelAddress? = nil) async throws {
        guard let address = address ?? replyAddress,
              let channel = channels[address.kind] else { return }
        try await channel.sendDocument(chatId: address.chatId, documentData: documentData, filename: filename, caption: caption, mimeType: mimeType)
    }

    /// (Re)register the Telegram channel from the current Keychain values.
    /// Since the app window became a transport of its own, Telegram can be
    /// added, corrected, or removed while the agent is already running —
    /// Settings and onboarding call this so the change takes effect live.
    /// The poll loop re-reads `isTelegramConfigured` on every tick, so a
    /// newly saved token starts receiving within a second, no restart needed.
    /// Startup reconciliation of one channel identity against the machine
    /// registry; false (with a log line) when another assistant holds it or
    /// the registry cannot be read.
    nonisolated static func registryAllowsChannel(_ kind: AssistantRegistry.Kind, value: String,
                                                  profile: String = AssistantProfile.selectedName,
                                                  paths: AssistantRegistry.Paths = .live,
                                                  load: (String) -> String? = { KeychainHelper.load(key: $0) }) -> Bool {
        // The persisted value is read under the registry lock (plan §5.6);
        // if it no longer equals what this process is about to use, the
        // reconciliation aborts WITHOUT touching this assistant's reservation
        // and the channel waits for the next registration (Codex stage-1 R5).
        let expected = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = kind == .bot ? KeychainHelper.telegramBotTokenKey : KeychainHelper.agentMailInboxAddressKey
        let result = AssistantRegistry.reconcile(profile: profile, kind: kind, readChecked: {
            let persisted = load(key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return persisted == expected ? .configured(persisted) : .aborted
        }, paths: paths)
        switch result {
        case .noRegistry, .allowed:
            return true
        case .changed:
            print("[Assistants] \(kind == .bot ? "Telegram" : "AgentMail") not started: its setting changed while starting; retrying at the next registration")
            return false
        case .conflict(let message), .busy(let message):
            print("[Assistants] \(kind == .bot ? "Telegram" : "AgentMail") not started: \(message)")
            return false
        }
    }

    func updateTelegramChannelRegistration() async {
        let token = (KeychainHelper.load(key: KeychainHelper.telegramBotTokenKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let chatId = (KeychainHelper.load(key: KeychainHelper.telegramChatIdKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var telegramConfigured = !token.isEmpty && Int(chatId) != nil
        // Several assistants on one computer (MULTI_ASSISTANT_PLAN §5.6): two
        // pollers on one bot steal each other's updates, so a bot another
        // assistant holds is never polled. No registry → no change.
        if telegramConfigured, !Self.registryAllowsChannel(.bot, value: token) {
            telegramConfigured = false
        }
        // /stop visibility: a token change (or removal) is a new transport
        // identity for visibility notices — bump BEFORE the actor adopts it.
        let tokenIdentity = telegramConfigured ? TelegramBotService.credentialIdentity(token) : nil
        if let previous = registeredTelegramTokenIdentity, previous != tokenIdentity {
            NoticeChannelGenerations.bump(.telegram)
            invalidateNoticeSeries(kind: .telegram)
        }
        registeredTelegramTokenIdentity = tokenIdentity
        if telegramConfigured {
            pairedChatId = Int(chatId)
            await telegramService.configure(token: token)
            channels[.telegram] = telegramService
            // Register the "/" command menu shown in Telegram. Cosmetic only
            // (the commands work regardless), so run detached and swallow
            // failures — a transient error must never block channel setup.
            // The menu is deliberately trimmed to the everyday commands;
            // /commands lists the rest (single source: ChatCommandRegistry).
            Task { [telegramService] in
                try? await telegramService.setMyCommands(ChatCommandRegistry.menuCommands)
            }
        } else {
            pairedChatId = nil
            channels.removeValue(forKey: .telegram)
            // Don't leave ambient output pointed at a removed channel.
            if lastUserChannelAddress?.kind == .telegram {
                lastUserChannelAddress = nil
            }
        }
        isTelegramConfigured = telegramConfigured
    }

    func sendFromApp(text: String, attachments: [URL],
                     policy: AttachmentPolicy = .appSocket) async -> AppSubmitOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return .refused("empty message") }

        // The composer bypasses the poll loop, so it needs its own restore gate.
        guard !admissionPaused else { return .refused(Self.updatingRefusal) }
        guard !isRestoringMind else {
            return .refused(browserSettingsMutation ? "browser settings are being updated — try again in a moment" : "memory restore in progress — try again in a moment")
        }

        browserSettingsAppIngress += 1
        defer { browserSettingsAppIngress -= 1 }

        // Typing in the app implies the agent should be running.
        if !isPolling {
            await startPolling()
            if let startupError = error {
                return .refused(startupError)
            }
        }

        var images: [(fileName: String, fileSize: Int)] = []
        var documents: [(fileName: String, fileSize: Int)] = []
        var copiedURLs: [URL] = []
        func discardCopies() {
            for url in copiedURLs { try? FileManager.default.removeItem(at: url) }
        }
        for url in attachments {
            let isImage = FilesystemTools.mimeType(forPath: url.path).hasPrefix("image/")
            let directory = isImage ? imagesDirectory : documentsDirectory
            // Name reservation is O_EXCL inside the copy: uniqueFileName's
            // pick can go stale during the awaited copy (a concurrent client
            // choosing the same name), so losing the exclusive create is not
            // an error — re-pick and retry, bounded against pathologia.
            var attemptsLeft = 5
            copyLoop: while true {
                let fileName = uniqueFileName(url.lastPathComponent, in: directory)
                let destination = directory.appendingPathComponent(fileName)
                do {
                    let size = try await Self.copyRegularFile(
                        from: url, to: destination,
                        maxBytes: policy.maxBytes,
                        allowEmpty: policy.allowEmpty)
                    copiedURLs.append(destination)
                    if isImage {
                        // Provider-refused formats (HEIC/TIFF/BMP/…) are not
                        // filed as images (plan v2 §2.3): converted copy as
                        // the image, original kept as a document.
                        let filed = fileIngestedImage(at: destination, fileName: fileName, size: size)
                        copiedURLs.removeLast()
                        copiedURLs.append(contentsOf: filed.created)
                        images.append(contentsOf: filed.images)
                        documents.append(contentsOf: filed.documents)
                    } else {
                        documents.append((fileName, size))
                    }
                    break copyLoop
                } catch is CopyDestinationExists {
                    attemptsLeft -= 1
                    guard attemptsLeft > 0 else {
                        discardCopies()
                        return .refused("attachment \(url.lastPathComponent): could not reserve a destination file name")
                    }
                } catch {
                    // All-or-nothing: with acceptance now a durability
                    // promise, silently dropping one attachment would be a
                    // lie. Refuse the whole submission; the app restores the
                    // composer for a retry.
                    discardCopies()
                    return .refused("attachment \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }

        let content = trimmed.isEmpty ? "I sent you some files as attachments." : trimmed
        let userMessage = Message(
            role: .user,
            content: content,
            imageFileNames: images.map(\.fileName),
            documentFileNames: documents.map(\.fileName),
            imageFileSizes: images.map(\.fileSize),
            documentFileSizes: documents.map(\.fileSize),
            originChannel: Self.appChannelAddress
        )

        // Unreadable history (1a round 4): no turn may start and nothing may
        // replace the recovery state it is protecting. Hold the message in
        // the durable mid-turn queue file (recovered, in order, once history
        // loads again) or refuse if even that write fails.
        if historyLoadFailure != nil {
            guard holdInboundWhileHistoryUnreadable(userMessage) else {
                discardCopies()
                return .refused("could not persist your message (disk problem?) — it was NOT accepted, try again")
            }
            return .heldForRecovery(Self.historyHoldNotice)
        }
        // Unreadable held-message file with readable history (1a round 6):
        // nothing may be written over it and no work may start ahead of the
        // messages it holds — refuse; the user retries after repair.
        if heldQueueFileProblem != nil {
            discardCopies()
            return .refused(Self.heldQueueRefusalNotice)
        }

        // Durable enqueue, then accept. Unlike the Telegram path (which keeps
        // an unpersisted message in memory and blocks the poll-offset ack so
        // the update re-delivers), the app socket has no redelivery — so a
        // failed write must ROLL BACK and refuse, putting the retry in the
        // user's hands instead of pretending acceptance.
        if activeRunId != nil || activeProcessingTask != nil {
            pendingMidTurnMessages.append(userMessage)
            guard persistPendingMidTurnQueue() else {
                pendingMidTurnMessages.removeAll { $0.id == userMessage.id }
                persistPendingMidTurnQueue()
                discardCopies()
                return .refused("could not persist your message (disk problem?) — it was NOT accepted, try again")
            }
            DebugTelemetry.log(
                .info,
                summary: "queued app msg during active turn",
                detail: String(userMessage.content.prefix(200))
            )
            noteMidTurnEnqueued(userMessage)
            statusMessage = "Message queued for in-flight turn"
            return .queuedMidTurn
        }

        messages.append(userMessage)
        guard saveConversation() else {
            messages.removeAll { $0.id == userMessage.id }
            discardCopies()
            return .refused("could not persist your message (disk problem?) — it was NOT accepted, try again")
        }
        statusMessage = "Generating response..."
        startActiveProcessing(for: userMessage)
        return .accepted
    }

    /// Streamed, revalidating file copy for app attachments. Runs off the
    /// main actor (nonisolated async). The source is opened with O_NONBLOCK
    /// so a FIFO with no writer cannot block the open, then fstat on the OPEN
    /// descriptor must report a regular file — closing the classic
    /// check-then-open race and rejecting devices, FIFOs and sockets no
    /// matter what a pre-check saw. Bytes are copied in 1 MB chunks with the
    /// cap enforced on actual bytes read (a lying st_size can't help). The
    /// destination is created O_CREAT|O_EXCL: name reservation is atomic at
    /// the filesystem, so two concurrent copies can never truncate or
    /// interleave into the same file — the loser throws
    /// CopyDestinationExists and the caller picks a fresh name.
    /// Selftests: suspends an attachment copy before it opens the source.
    nonisolated(unsafe) static var copyRegularFileGateForTesting: (() async -> Void)?

    nonisolated static func copyRegularFile(
        from source: URL, to destination: URL, maxBytes: Int,
        allowEmpty: Bool = false
    ) async throws -> Int {
        if let gate = copyRegularFileGateForTesting { await gate() }
        struct CopyError: LocalizedError {
            let message: String
            var errorDescription: String? { message }
        }
        let fd = open(source.path, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else {
            throw CopyError(message: "could not open (\(String(cString: strerror(errno))))")
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw CopyError(message: "could not stat")
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw CopyError(message: "not a regular file — only ordinary files can be attached")
        }
        // Regular files never block on read; drop O_NONBLOCK for portability.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) & ~O_NONBLOCK)

        let destFD = open(destination.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard destFD >= 0 else {
            if errno == EEXIST { throw CopyDestinationExists() }
            throw CopyError(message: "could not create the destination file (\(String(cString: strerror(errno))))")
        }
        let output = FileHandle(fileDescriptor: destFD, closeOnDealloc: true)
        defer { try? output.close() }

        var total = 0
        var chunk = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n == 0 { break }
            if n < 0 {
                if errno == EINTR { continue }
                try? FileManager.default.removeItem(at: destination)
                throw CopyError(message: "read failed (\(String(cString: strerror(errno))))")
            }
            total += n
            guard total <= maxBytes else {
                try? FileManager.default.removeItem(at: destination)
                throw CopyError(message: "larger than \(maxBytes / 1_048_576) MB")
            }
            do {
                try output.write(contentsOf: Data(bytes: chunk, count: n))
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw CopyError(message: "write failed (disk full?)")
            }
        }
        guard total > 0 || allowEmpty else {
            try? FileManager.default.removeItem(at: destination)
            throw CopyError(message: "the file is empty")
        }
        return total
    }

    /// Stop button in the app's chat composer — same blanket halt as /stop.
    /// Notification is routed to the app channel (a no-op send): the salvage
    /// path already appends a visible "turn interrupted" message to history.
    func stopFromApp() async {
        await stopActiveExecution(notify: Self.appChannelAddress)
    }

    // MARK: - App-socket front-end support

    /// Absolute media folders for socket front-ends (the UT companion app).
    /// Message events carry attachment file NAMES; the app joins them onto
    /// these directories locally — no file bytes cross the socket.
    var mediaDirectoryPaths: (images: String, documents: String) {
        (imagesDirectory.path, documentsDirectory.path)
    }

    /// Voice note handed over by the app socket: transcribe with the same
    /// provider rules as a Telegram voice message and return the text or a
    /// user-facing reason. Never dispatches a turn — the socket server acks
    /// with the transcription first (so the app can replace its
    /// "transcribing…" placeholder), then submits it via sendFromApp.
    func transcribeAppVoice(audioURL: URL) async -> Result<String, AppVoiceTranscriptionError> {
        let provider = currentVoiceTranscriptionProvider()
        statusMessage = provider == .openAI
            ? "Transcribing audio with \(MediaRouting.transcription.viaOpenRouter ? "OpenRouter" : "OpenAI")..."
            : "Transcribing audio locally..."
        switch provider {
        case .openAI:
            let transcriptionRoute = MediaRouting.transcription
            let apiKey = transcriptionRoute.key
            guard !apiKey.isEmpty else {
                statusMessage = "OpenAI API key missing"
                return .failure(.notConfigured(
                    "the OpenAI transcription key isn't configured — add it in Settings (or run `briglia setup`, step 2)"))
            }
            do {
                let transcription = try await OpenAITranscriptionService.shared
                    .transcribeAudioFile(url: audioURL, apiKey: apiKey, prompt: TranscriptionVocabulary.chatHint(), endpoint: .init(transcriptionRoute))
                guard !transcription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return .failure(.failed("the recording sounded empty"))
                }
                return .success(transcription)
            } catch {
                return .failure(.failed(error.localizedDescription))
            }
        case .local:
            guard WhisperKitService.shared.isModelReady else {
                statusMessage = "Voice model not ready"
                return .failure(.notConfigured(
                    "local transcription isn't available in Briglia CLI — switch to OpenAI transcription (/transcribe_openai)"))
            }
            guard let transcription = await WhisperKitService.shared.transcribeAudioFile(url: audioURL),
                  !transcription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(.failed("transcription failed"))
            }
            return .success(transcription)
        }
    }

    /// Persist an agent-sent photo (send_document_to_chat with an image, on
    /// an app-originated turn) and append it to history as a visible message.
    func appendAppChannelPhoto(data: Data, caption: String?, mimeType: String) async {
        let ext: String
        switch mimeType.lowercased() {
        case "image/jpeg", "image/jpg": ext = "jpg"
        case "image/gif": ext = "gif"
        case "image/webp": ext = "webp"
        case "image/heic": ext = "heic"
        default: ext = "png"
        }
        let fileName = uniqueFileName("ada-\(UUID().uuidString.prefix(8)).\(ext)", in: imagesDirectory)
        do {
            try PrivateStorage.writeAtomically(data, to: imagesDirectory.appendingPathComponent(fileName))
        } catch {
            print("[ConversationManager] Failed to persist app-channel photo: \(error)")
            return
        }
        let message = Message(
            role: .assistant,
            content: caption ?? "",
            imageFileNames: [fileName],
            imageFileSizes: [data.count]
        )
        messages.append(message)
        saveConversation()
    }

    /// Persist an agent-sent document and append it to history as a visible
    /// message whose file chip can be revealed in Finder.
    func appendAppChannelDocument(data: Data, filename: String, caption: String?) async {
        let safeName = uniqueFileName(URL(fileURLWithPath: filename).lastPathComponent, in: documentsDirectory)
        do {
            try PrivateStorage.writeAtomically(data, to: documentsDirectory.appendingPathComponent(safeName))
        } catch {
            print("[ConversationManager] Failed to persist app-channel document: \(error)")
            return
        }
        let message = Message(
            role: .assistant,
            content: caption ?? "",
            documentFileNames: [safeName],
            documentFileSizes: [data.count]
        )
        messages.append(message)
        saveConversation()
    }

    /// Resolve a document attachment filename (documentFileNames,
    /// downloadedDocumentFileNames, referencedDocumentFileNames) to its URL in
    /// the conversation documents folder, or nil if the file no longer exists.
    func urlForDocumentAttachment(_ fileName: String) -> URL? {
        let url = documentsDirectory.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// First free filename in `directory` for a proposed name: keeps the
    /// original name, appending "-2", "-3", … before the extension on clashes
    /// so attachments never overwrite one another.
    /// An image copied into the images directory, filed by what providers
    /// accept (ModelImage): a supported image stays as it is; a convertible
    /// one becomes a converted image plus the original as a document; a
    /// refused one (malformed, or no converter here) becomes a document only,
    /// where read_file explains why it cannot be attached. Any file-system
    /// failure keeps the original as an image (the request guard still
    /// converts or notes it at send time).
    private func fileIngestedImage(at url: URL, fileName: String, size: Int)
        -> (images: [(fileName: String, fileSize: Int)], documents: [(fileName: String, fileSize: Int)], created: [URL]) {
        let unchanged = ([(fileName: fileName, fileSize: size)], [(fileName: String, fileSize: Int)](), [url])
        guard let data = try? Data(contentsOf: url) else { return unchanged }
        let outcome = ModelImage.classifyCached(data: data)
        if case .supported = outcome { return unchanged }
        let documentName = uniqueFileName(fileName, in: documentsDirectory)
        let documentURL = documentsDirectory.appendingPathComponent(documentName)
        do { try FileManager.default.moveItem(at: url, to: documentURL) } catch { return unchanged }
        guard case .converted(let converted, let mime, _) = outcome else {
            return ([], [(documentName, size)], [documentURL])
        }
        let base = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        let imageName = uniqueFileName(base + (mime == "image/png" ? ".png" : ".jpg"), in: imagesDirectory)
        let imageURL = imagesDirectory.appendingPathComponent(imageName)
        do { try PrivateStorage.writeAtomically(converted, to: imageURL) } catch {
            return ([], [(documentName, size)], [documentURL])
        }
        return ([(imageName, converted.count)], [(documentName, size)], [imageURL, documentURL])
    }

    private func uniqueFileName(_ proposed: String, in directory: URL) -> String {
        let proposedURL = URL(fileURLWithPath: proposed)
        let base = proposedURL.deletingPathExtension().lastPathComponent
        let ext = proposedURL.pathExtension
        var candidate = ext.isEmpty ? base : "\(base).\(ext)"
        var counter = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            counter += 1
        }
        return candidate
    }
    var maxToolRoundsSafetyLimit: Int {
        AgentTurnOverrides.override(forAgent: "main") ?? AgentTurnOverrides.mainAgentDefault
    }
    
    var conversationFileURL: URL {
        appFolder.appendingPathComponent("conversation.json")
    }

    var contextUsageFileURL: URL {
        appFolder.appendingPathComponent("context_usage.json")
    }

    var pendingContinuationFileURL: URL {
        appFolder.appendingPathComponent("pending_continuation.json")
    }

    /// Crash-proof mirror of the in-progress turn's salvage buffer. Present on
    /// disk only while a turn is running; consumed at launch if the previous
    /// process died mid-turn before any outcome reached conversation.json.
    var turnSalvageFileURL: URL {
        appFolder.appendingPathComponent("turn_salvage.json")
    }

    /// Durable mirror of pendingMidTurnMessages. The Telegram offset is
    /// confirmed per update as soon as processUpdate returns — for a mid-turn
    /// arrival that means "queued", not "answered", and Telegram will never
    /// re-serve a confirmed update. Without this file a crash during the
    /// active turn silently lost every queued message. Present on disk only
    /// while the queue is non-empty; consumed at the next startPolling.
    var pendingMidTurnFileURL: URL {
        appFolder.appendingPathComponent("pending_midturn.json")
    }

    /// Durable mirror of the pending inbound attachment buffers (captionless
    /// media waiting for its follow-up text). Restored at launch so a crash
    /// between "attachment received" and the text that triggers it doesn't
    /// orphan the files.
    var pendingAttachmentsFileURL: URL {
        appFolder.appendingPathComponent("pending_attachments.json")
    }

    /// Durable mirror of pendingAmbientTriggers (email arrivals deferred
    /// behind an active turn). The AgentMail poller checkpoints its
    /// watermark only after the handler reports the event durable — without
    /// this file, "durable" for the deferred path meant an in-memory queue,
    /// and a crash lost the notification while the restored checkpoint
    /// skipped refetching it (Codex round 6, 2026-08-22). Present on disk
    /// only while the queue is non-empty; consumed at the next startPolling.
    var pendingAmbientFileURL: URL {
        appFolder.appendingPathComponent("pending_ambient.json")
    }

    /// Present on disk only while a turn triggered by a real user message is
    /// running. The trigger is already in conversation history and its update
    /// confirmed to Telegram, so after a power failure nothing re-delivers —
    /// this marker is what lets startup notice the unanswered message and
    /// resume the turn.
    var activeTurnMarkerFileURL: URL {
        appFolder.appendingPathComponent("active_turn.json")
    }
    
    var imagesDirectory: URL {
        let dir = appFolder.appendingPathComponent("images", isDirectory: true)
        try? PrivateStorage.ensureDirectory(dir)
        return dir
    }
    
    var documentsDirectory: URL {
        let dir = appFolder.appendingPathComponent("documents", isDirectory: true)
        try? PrivateStorage.ensureDirectory(dir)
        return dir
    }

    var toolAttachmentsDirectory: URL {
        let dir = appFolder.appendingPathComponent("tool_attachments", isDirectory: true)
        try? PrivateStorage.ensureDirectory(dir)
        return dir
    }
}
