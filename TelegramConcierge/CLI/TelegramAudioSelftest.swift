import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Hidden battery for Telegram audio files, video notes and unreadable
/// messages (private-docs plan CACHE_KEY_AND_IMAGE_REJECTION_PLAN v2 §3.5),
/// plus the owner's voice-note rule: a `voice` update behaves exactly as in
/// v0.2.51 (download, automatic transcription request, trigger text, saved
/// message, failure texts). `--voice-trace` prints the voice rows' observed
/// sequence as normalized JSON lines, so the same command built from v0.2.51
/// (with only these test seams added) can be diffed against this build.
///
/// Every Bot API and file request is answered in process
/// (TelegramBotService.transportOverrideForTesting); transcription uses the
/// existing fake-transport seam; the model is the scripted capture server.
/// Re-executes itself in a private scratch home and preference domain.
struct TelegramAudioSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__telegram-audio-selftest",
        abstract: "Internal: verify Telegram audio/video-note handling and the unchanged voice path.",
        shouldDisplay: false
    )

    @Flag(name: .long, help: .hidden) var child = false
    @Flag(name: .long, help: .hidden) var voiceTrace = false
    @Option(name: .long, help: .hidden) var only: String?

    static let linkName = "briglia-mw-tgaudio"
    static let rootPrefix = "briglia-telegram-audio-"

    @MainActor func run() async throws {
        guard adaCLIVersion.hasSuffix("-dev") else {
            print("✖ development build required"); throw ExitCode(1)
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        guard child else { try Self.reexecIsolated(only: only, voiceTrace: voiceTrace); return }
        let h = MidturnHarness(only: only)
        try await h.runTelegramAudio(voiceTraceOnly: voiceTrace)
        if h.failures > 0 {
            print("\n\(h.failures) of \(h.total) telegram audio check(s) FAILED")
            throw ExitCode(1)
        }
        print("\nAll \(h.total) telegram audio checks passed")
    }

    static func reexecIsolated(only: String?, voiceTrace: Bool) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(rootPrefix + UUID().uuidString)
        for sub in ["home", "home/.config", "home/.local/share", "tmp"] {
            try fm.createDirectory(at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: root) }
        let home = root.appendingPathComponent("home").path
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home
        env["CFFIXED_USER_HOME"] = home
        env["XDG_CONFIG_HOME"] = home + "/.config"
        env["XDG_DATA_HOME"] = home + "/.local/share"
        env["TMPDIR"] = root.appendingPathComponent("tmp").path + "/"
        env.removeValue(forKey: "BRIGLIA_TELEGRAM_API_BASE")
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).resolvingSymlinksInPath()
        let linked = root.appendingPathComponent(linkName)
        if link(source.path, linked.path) != 0 { try fm.copyItem(at: source, to: linked) }
        let process = Process()
        process.executableURL = linked
        process.arguments = ["__telegram-audio-selftest", "--child"] + (voiceTrace ? ["--voice-trace"] : [])
            + (only.map { ["--only", $0] } ?? [])
        process.environment = env
        try process.run()
        process.waitUntilExit()
        TestPrefsDomains.purge(linkName)
        TestPrefsDomains.finalSweep()
        if process.terminationStatus != 0 { throw ExitCode(process.terminationStatus) }
    }
}

/// In-process Bot API: getFile answers with a path equal to the file id,
/// file downloads return per-id bytes (or fail), sendMessage is recorded.
final class TGFakeBotAPI: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [String] = []
    private var _sent: [String] = []
    var files: [String: Data] = [:]
    var failingFiles: Set<String> = []

    var requests: [String] { lock.lock(); defer { lock.unlock() }; return _requests }
    var sent: [String] { lock.lock(); defer { lock.unlock() }; return _sent }
    func clear() { lock.lock(); _requests = []; _sent = []; lock.unlock() }

    func handle(_ request: URLRequest) -> (Data, URLResponse) {
        let url = request.url!
        let path = url.path
        func reply(_ object: Any, status: Int = 200) -> (Data, URLResponse) {
            let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                          headerFields: ["Content-Type": "application/json"])!)
        }
        let method = path.components(separatedBy: "/").last ?? ""
        if path.contains("/file/bot") {
            let id = method
            lock.lock(); _requests.append("download:\(id)"); let data = files[id]; let fail = failingFiles.contains(id); lock.unlock()
            if fail || data == nil { return reply(["ok": false, "description": "Bad Request: file unavailable"], status: 400) }
            return (data!, HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
        if method == "getFile" {
            let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "file_id" }?.value ?? ""
            lock.lock(); _requests.append("getFile:\(id)"); let size = files[id]?.count ?? 0; lock.unlock()
            return reply(["ok": true, "result": ["file_id": id, "file_unique_id": "u-" + id, "file_size": size, "file_path": id]])
        }
        if method == "sendMessage" {
            let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            lock.lock(); _requests.append("sendMessage"); _sent.append(body["text"] as? String ?? ""); lock.unlock()
            return reply(["ok": true, "result": ["message_id": 1, "date": 0, "chat": ["id": 424242, "type": "private"]]])
        }
        lock.lock(); _requests.append(method); lock.unlock()
        return reply(["ok": true, "result": true])
    }
}

/// Fake transcription transport: records each request, answers with a
/// fixed text or an HTTP error.
final class TGFakeTranscription: @unchecked Sendable {
    private let lock = NSLock()
    private var _bodies: [(url: String, body: Data)] = []
    var failWith: Int?
    var text = "transcribed voice text"
    var bodies: [(url: String, body: Data)] { lock.lock(); defer { lock.unlock() }; return _bodies }
    func clear() { lock.lock(); _bodies = []; lock.unlock() }

    func handle(_ request: URLRequest) -> (Data, URLResponse) {
        lock.lock(); _bodies.append((request.url?.absoluteString ?? "", request.httpBody ?? Data())); let fail = failWith; lock.unlock()
        let status = fail ?? 200
        let object: [String: Any] = fail == nil ? ["text": text] : ["error": ["message": "synthetic transcription outage"]]
        return (try! JSONSerialization.data(withJSONObject: object),
                HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                headerFields: ["Content-Type": "application/json"])!)
    }
}

extension MidturnHarness {

    static let tgChatId = 424242
    static let tgToken = "1234567890:AAsyntheticTelegramTokenForSelftests00"

    func runTelegramAudio(voiceTraceOnly: Bool) async throws {
        let data = StoragePaths.dataRoot.path
        guard data.contains(TelegramAudioSelftest.rootPrefix),
              ProcessInfo.processInfo.processName == TelegramAudioSelftest.linkName else {
            print("✖ refusing to run outside the isolated scratch home / private preference domain (data root \(data))")
            failures += 1; return
        }
        server = try CaptureServer()
        defer { server.stop() }
        try configureProvider()
        if voiceTraceOnly { try await tgVoiceTrace(); return }
        if section("decode") { tgDecodeSection() }
        if section("voice") { try await tgVoiceTrace() }
        if section("field") { try await tgFieldCase() }
        if section("audio") { try await tgAudioSection() }
        if section("malformed") { try await tgMalformedSection() }
        if section("safety") { try await tgSafetyNetSection() }
        if section("whatsapp") { try await tgWhatsAppSection() }
    }

    /// A manager with the REAL Telegram channel, answered in process.
    func tgManager(api: TGFakeBotAPI, transcription: TGFakeTranscription, openAIKey: String? = "synthetic-openai-transcription-key") async -> ConversationManager {
        try? KeychainHelper.delete(key: KeychainHelper.telegramBotTokenKey)
        try? KeychainHelper.delete(key: KeychainHelper.telegramChatIdKey)
        let manager = await freshManager()
        TelegramBotService.transportOverrideForTesting = { api.handle($0) }
        OpenAITranscriptionService.overrideForTesting = OpenAITranscriptionService(transport: { transcription.handle($0) })
        if let openAIKey { try? KeychainHelper.save(key: KeychainHelper.openAITranscriptionApiKeyKey, value: openAIKey) }
        else { try? KeychainHelper.delete(key: KeychainHelper.openAITranscriptionApiKeyKey) }
        try? KeychainHelper.save(key: KeychainHelper.telegramBotTokenKey, value: Self.tgToken)
        try? KeychainHelper.save(key: KeychainHelper.telegramChatIdKey, value: String(Self.tgChatId))
        await manager._svRegisterTelegram()
        return manager
    }

    /// A private-chat update from the paired user; `fields` are merged into
    /// the message object.
    static func tgUpdate(_ id: Int, _ fields: [String: Any], chat: Int = tgChatId, from: Int = tgChatId) -> TelegramUpdate {
        var message: [String: Any] = ["message_id": id, "date": 1_790_000_000,
                                      "chat": ["id": chat, "type": "private", "first_name": "Owner"],
                                      "from": ["id": from, "is_bot": false, "first_name": "Owner"]]
        message.merge(fields) { _, new in new }
        let data = try! JSONSerialization.data(withJSONObject: ["update_id": id, "message": message])
        return try! JSONDecoder().decode(TelegramUpdate.self, from: data)
    }

    /// The field report, replayed with only APIs that exist in v0.2.51 too
    /// (so the same rows prove the bug on a v0.2.51 build): four .m4a audio
    /// files (1.3 / 4.4 / 15.2 / 29.4 MB) then "transcribe them", and a
    /// sticker. v0.2.51 drops the audio silently and never answers the
    /// sticker.
    func tgFieldCase() async throws {
        let api = TGFakeBotAPI(), transcription = TGFakeTranscription()
        let manager = await tgManager(api: api, transcription: transcription)
        let mb = 1024 * 1024
        for (i, size) in [Int(1.3 * Double(mb)), Int(4.4 * Double(mb)), Int(15.2 * Double(mb)), Int(29.4 * Double(mb))].enumerated() {
            api.files["field\(i)"] = Data(repeating: UInt8(i), count: 1024)
            await manager._testProcessUpdate(Self.tgUpdate(500 + i, ["audio": [
                "file_id": "field\(i)", "file_unique_id": "uf\(i)", "duration": 600 + i, "file_name": "Nuova registrazione \(i + 3).m4a",
                "mime_type": "audio/mp4", "file_size": size]]))
        }
        server.script([Self.chatText("ok")])
        await manager._testProcessUpdate(Self.tgUpdate(504, ["text": "Puoi trasformare in testo queste registrazioni?"]))
        _ = await manager._testAwaitIdle(timeout: 30)
        let user = manager._testMessages.first { $0.role == .user }
        let downloads = api.requests.filter { $0.hasPrefix("download:field") }
        print("FIELD-TRACE downloads=\(downloads.count) documents=\(user?.documentFileNames.count ?? -1) transcriptions=\(transcription.bodies.count) notices=\(api.sent.filter { $0.hasPrefix("⚠️") }.count)")
        check("F1 field case: the three audio files under 20 MB reach the turn as files, the 29.4 MB one gets the oversize notice, nothing is transcribed",
              downloads.count == 3 && user?.documentFileNames.count == 3 && transcription.bodies.isEmpty
                && api.sent.filter { $0.contains("Nuova registrazione 6.m4a") && $0.contains("20 MB") }.count == 1,
              "downloads \(downloads.count) documents \(user?.documentFileNames.count ?? -1) sent \(api.sent)")
        api.clear()
        await manager._testProcessUpdate(Self.tgUpdate(510, ["sticker": ["file_id": "st", "file_unique_id": "ust", "type": "regular", "width": 1, "height": 1]]))
        print("FIELD-TRACE sticker_replies=\(api.sent.count)")
        check("F2 a sticker gets one visible reply instead of silence", api.sent.count == 1 && api.sent[0].contains("sticker"), "\(api.sent)")
        TelegramBotService.transportOverrideForTesting = nil
        OpenAITranscriptionService.overrideForTesting = nil
    }

    /// Owner rule: a voice note behaves exactly as in v0.2.51. Prints
    /// `VOICE-TRACE` lines (normalized: no ids, no times, no temp paths) and
    /// checks the v0.2.51 literals. The differential evidence diffs these
    /// lines between this build and a v0.2.51 build with the same seams.
    func tgVoiceTrace() async throws {
        func trace(_ label: String, _ value: Any) {
            let data = (try? JSONSerialization.data(withJSONObject: [label: value], options: [.sortedKeys])) ?? Data()
            print("VOICE-TRACE " + String(decoding: data, as: UTF8.self))
        }
        let api = TGFakeBotAPI(), transcription = TGFakeTranscription()
        let voiceBytes = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        api.files["voice-1"] = voiceBytes
        let voice: [String: Any] = ["voice": ["file_id": "voice-1", "file_unique_id": "uv1", "duration": 4,
                                              "mime_type": "audio/ogg", "file_size": voiceBytes.count]]
        // 1. Success: download, transcription request, trigger, saved message.
        let manager = await tgManager(api: api, transcription: transcription)
        server.script([Self.chatText("voice reply")])
        api.clear()
        await manager._testProcessUpdate(Self.tgUpdate(9001, voice))
        _ = await manager._testAwaitIdle(timeout: 30)
        let bodies = transcription.bodies
        let multipart = String(decoding: bodies.first?.body ?? Data(), as: UTF8.self)
        func field(_ name: String) -> String? {
            guard let range = multipart.range(of: "name=\"\(name)\"\r\n\r\n") else { return nil }
            return String(multipart[range.upperBound...].prefix { $0 != "\r\n" && $0 != "\r" })
        }
        let user = manager._testMessages.first { $0.role == .user }
        var saved: [String: Any] = [:]
        if let user, let data = try? JSONEncoder().encode(user),
           var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object.removeValue(forKey: "id"); object.removeValue(forKey: "timestamp")
            saved = object
        }
        let llm = requestBodies().first ?? ""
        trace("telegram_requests", api.requests.filter { $0 != "setMyCommands" && $0 != "setMessageReaction" })
        trace("transcription_requests", bodies.count)
        trace("transcription_url", bodies.first?.url ?? "")
        var names: [String] = []
        var cursor = multipart.startIndex
        while let range = multipart.range(of: "name=\"", range: cursor..<multipart.endIndex) {
            let rest = multipart[range.upperBound...]
            names.append(String(rest.prefix { $0 != "\"" })); cursor = range.upperBound
        }
        trace("transcription_field_names", names.map {
            $0.replacingOccurrences(of: "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}", with: "<uuid>", options: .regularExpression)
        })
        trace("transcription_fields", ["model": field("model") ?? "", "prompt": field("prompt") ?? "",
                                        "response_format": field("response_format") ?? "",
                                        "file_bytes_match": multipart.utf8.count > 0 && (bodies.first?.body.range(of: voiceBytes) != nil)])
        trace("saved_message", saved)
        trace("trigger_reached_model", llm.contains(transcription.text))
        trace("sent_texts", api.sent)
        check("V1 voice: getFile + one download, one transcription request with the vocabulary prompt, the transcript is the turn's text",
              api.requests.contains("getFile:voice-1") && api.requests.contains("download:voice-1") && bodies.count == 1
                && field("prompt") == TranscriptionVocabulary.chatHint() && user?.content == transcription.text
                && user?.documentFileNames.isEmpty == true && user?.imageFileNames.isEmpty == true && llm.contains(transcription.text),
              "\(api.requests) \(bodies.count)")
        // 2. The three v0.2.51 failure texts, verbatim.
        let missingKey = await tgManager(api: api, transcription: transcription, openAIKey: nil)
        api.clear()
        await missingKey._testProcessUpdate(Self.tgUpdate(9002, voice))
        let keyText = "⚠️ I couldn't process your voice message: the OpenAI transcription key isn't configured (run `briglia setup`, step 2). Type the message as text, or fix the key."
        let sentMissing = api.sent
        trace("failure_missing_key", sentMissing)
        let failingDownload = await tgManager(api: api, transcription: transcription)
        api.clear(); api.failingFiles = ["voice-1"]
        await failingDownload._testProcessUpdate(Self.tgUpdate(9003, voice))
        api.failingFiles = []
        let sentDownload = api.sent
        trace("failure_download", sentDownload)
        let failingTranscription = await tgManager(api: api, transcription: transcription)
        api.clear(); transcription.failWith = 500
        await failingTranscription._testProcessUpdate(Self.tgUpdate(9004, voice))
        transcription.failWith = nil
        let sentTranscription = api.sent
        trace("failure_transcription", sentTranscription)
        // The channel's Markdown cleanup drops the backticks on the wire, in
        // v0.2.51 as now.
        check("V2a missing key: the v0.2.51 text, verbatim", sentMissing == [keyText.replacingOccurrences(of: "`", with: "")], "\(sentMissing)")
        check("V2b download failure: the v0.2.51 text",
              sentDownload.count == 1 && sentDownload[0].hasPrefix("⚠️ I couldn't download your voice message from Telegram (")
                && sentDownload[0].hasSuffix("). Please try again or send it as text."), "\(sentDownload)")
        check("V2c transcription failure: the v0.2.51 text",
              sentTranscription.count == 1 && sentTranscription[0].hasPrefix("⚠️ I couldn't transcribe your voice message (")
                && sentTranscription[0].hasSuffix("). Try again, or type it as text."), "\(sentTranscription)")
        TelegramBotService.transportOverrideForTesting = nil
        OpenAITranscriptionService.overrideForTesting = nil
    }
}
