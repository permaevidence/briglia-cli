import Foundation

/// WhatsApp (plan v2 §3.4, owner-confirmed split): a recorded voice note
/// (the bridge's "voice", from ptt) keeps automatic transcription; any other
/// audio file (the bridge's "audio") arrives as a file, never transcribed.
extension MidturnHarness {

    func tgWhatsAppSection() async throws {
        let api = TGFakeBotAPI(), transcription = TGFakeTranscription()
        func inbound(kind: String, file: String, mime: String, caption: String?) -> WhatsAppInboundMessage {
            let spool = StoragePaths.dataRoot.appendingPathComponent("wa-spool-\(UUID().uuidString)-\(file)")
            try? Data(repeating: 5, count: 700).write(to: spool)
            var object: [String: Any] = ["from": "393330000000@s.whatsapp.net", "timestamp": 1_790_000_000,
                                         "media": ["kind": kind, "path": spool.path, "filename": file, "mimeType": mime, "sizeBytes": 700]]
            if let caption { object["caption"] = caption }
            return try! JSONDecoder().decode(WhatsAppInboundMessage.self, from: JSONSerialization.data(withJSONObject: object))
        }
        // Recorded voice note → transcribed exactly as before.
        var manager = await tgManager(api: api, transcription: transcription)
        server.clear(); server.script([Self.chatText("heard")])
        await manager._testProcessWhatsApp(inbound(kind: "voice", file: "PTT-20261009.ogg", mime: "audio/ogg; codecs=opus", caption: nil))
        _ = await manager._testAwaitIdle(timeout: 30)
        check("W1 WhatsApp recorded voice note: transcribed automatically, the transcript is the turn's text",
              transcription.bodies.count == 1 && manager._testMessages.first { $0.role == .user }?.content == transcription.text)
        // Ordinary audio file → a file with a note, no transcription.
        transcription.clear()
        manager = await tgManager(api: api, transcription: transcription)
        server.clear(); server.script([Self.chatText("got the file")])
        await manager._testProcessWhatsApp(inbound(kind: "audio", file: "song.m4a", mime: "audio/mp4", caption: "keep this"))
        _ = await manager._testAwaitIdle(timeout: 30)
        let user = manager._testMessages.first { $0.role == .user }
        check("W2 WhatsApp audio file: stored as a document with a 'not transcribed' note; no transcription request",
              transcription.bodies.isEmpty && user?.documentFileNames.first?.hasSuffix(".m4a") == true
                && user?.content.contains("keep this") == true && user?.content.contains("not transcribed") == true,
              "transcriptions \(transcription.bodies.count) docs \(user?.documentFileNames ?? [])")
        // The bridge maps ptt to the two kinds (static rule in the bundled
        // bridge source; the bridge itself needs Baileys to load).
        let bridge = Bundle.module.resourceURL.flatMap { try? String(contentsOf: $0.appendingPathComponent("WhatsAppBridge/index.js"), encoding: .utf8) } ?? ""
        check("W3 the bundled bridge sends ptt audio as 'voice' and every other audio message as 'audio'",
              bridge.contains("const ptt = msg.audioMessage.ptt === true")
                && bridge.contains("kind: ptt ? 'voice' : 'audio'"))
        TelegramBotService.transportOverrideForTesting = nil
        OpenAITranscriptionService.overrideForTesting = nil
    }
}
