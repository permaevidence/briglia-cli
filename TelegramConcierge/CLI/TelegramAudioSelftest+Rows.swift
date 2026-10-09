import Foundation

/// Audio files, video notes, malformed fields and the unreadable-message
/// safety net (plan v2 §3.5).
extension MidturnHarness {

    func tgDecodeSection() {
        func decode(_ message: [String: Any]) -> TelegramMessage? {
            var full: [String: Any] = ["message_id": 1, "date": 0, "chat": ["id": 1, "type": "private"]]
            full.merge(message) { _, new in new }
            return try? JSONDecoder().decode(TelegramMessage.self, from: JSONSerialization.data(withJSONObject: full))
        }
        let audio: [String: Any] = ["file_id": "a1", "file_unique_id": "ua1", "duration": 75, "performer": "Me", "title": "Memo",
                                    "file_name": "Nuova registrazione 1.m4a", "mime_type": "audio/mp4", "file_size": 1_363_148]
        let withName = decode(["audio": audio, "caption": "listen"])
        check("D1 audio with file name and caption decodes", withName?.audio?.fileName == "Nuova registrazione 1.m4a"
              && withName?.audioState == .decoded && withName?.caption == "listen")
        var noName = audio; noName.removeValue(forKey: "file_name"); noName.removeValue(forKey: "performer")
        check("D2 audio without a file name decodes", decode(["audio": noName])?.audio?.title == "Memo")
        let note = decode(["video_note": ["file_id": "v1", "file_unique_id": "uv1", "length": 240, "duration": 9, "file_size": 400_000]])
        check("D3 video_note decodes", note?.videoNote?.duration == 9 && note?.videoNoteState == .decoded)
        let reply = decode(["text": "what's this?", "reply_to_message": ["message_id": 7, "date": 0, "chat": ["id": 1, "type": "private"], "audio": audio]])
        check("D4 audio inside reply_to_message decodes", reply?.replyToMessage?.audio?.fileId == "a1" && reply?.text == "what's this?")
        let badAudio = decode(["audio": ["file_id": 12345, "duration": "long"], "caption": "kept", "text": nil as Any? ?? NSNull()])
        check("D5 malformed audio: the message still decodes, field present-undecodable, caption intact",
              badAudio != nil && badAudio?.audio == nil && badAudio?.audioState == .presentUndecodable && badAudio?.caption == "kept")
        let badNote = decode(["video_note": ["file_id": "v", "length": "x"], "text": "hello"])
        check("D6 malformed video_note: decodes, present-undecodable, text intact",
              badNote?.videoNoteState == .presentUndecodable && badNote?.text == "hello")
        let badReply = decode(["text": "re", "reply_to_message": ["message_id": 7, "date": 0, "chat": ["id": 1, "type": "private"], "audio": ["x": 1]]])
        check("D7 malformed audio inside a reply: both messages decode", badReply?.replyToMessage?.audioState == .presentUndecodable && badReply?.text == "re")
        check("D8 allowlisted kinds detected by key presence",
              decode(["sticker": ["file_id": "s"]])?.unreadableKinds == ["sticker"]
                && decode(["live_photo": ["anything": true]])?.unreadableKinds == ["live_photo"]
                && decode(["poll": 42])?.unreadableKinds == ["poll"])
        check("D9 service events and unknown keys are not unreadable kinds",
              ["pinned_message", "giveaway_created", "giveaway_completed", "checklist_tasks_done", "checklist_tasks_added",
               "new_chat_members", "write_access_allowed", "message_auto_delete_timer_changed", "some_future_field"]
                .allSatisfy { decode([$0: ["x": 1]])?.unreadableKinds.isEmpty == true })
        check("D10 a plain text message carries no new state",
              decode(["text": "hi"]).map { $0.audioState == .absent && $0.videoNoteState == .absent && $0.unreadableKinds.isEmpty } == true)
    }

    /// The field case (four audio files, one over 20 MB, then "transcribe
    /// them") and the 20 MB boundary.
    func tgAudioSection() async throws {
        let api = TGFakeBotAPI(), transcription = TGFakeTranscription()
        let manager = await tgManager(api: api, transcription: transcription)
        func audio(_ id: String, name: String, size: Int?) -> [String: Any] {
            var a: [String: Any] = ["file_id": id, "file_unique_id": "u" + id, "duration": 61, "file_name": name, "mime_type": "audio/mp4"]
            if let size { a["file_size"] = size }
            return ["audio": a]
        }
        let mb = 1024 * 1024
        let megabytes: [Double] = [1.3, 4.4, 15.2, 29.4]
        let sizes: [Int] = megabytes.map { (value: Double) -> Int in Int(value * Double(mb)) }
        for (i, size) in sizes.enumerated() {
            api.files["rec\(i)"] = Data(repeating: UInt8(i), count: 2048)
            await manager._testProcessUpdate(Self.tgUpdate(100 + i, audio("rec\(i)", name: "Nuova registrazione \(i + 3).m4a", size: size)))
        }
        check("A1 field case: three audio files buffered as documents, the 29.4 MB one refused with the existing notice",
              manager._testPendingDocumentCount == 3 && api.sent.count == 1 && api.sent[0].contains("Nuova registrazione 6.m4a")
                && api.sent[0].contains("20 MB") && !api.requests.contains("download:rec3"), "\(api.sent) \(api.requests)")
        server.script([Self.chatText("ok")])
        await manager._testProcessUpdate(Self.tgUpdate(104, ["text": "Puoi trasformare in testo questi audio?"]))
        _ = await manager._testAwaitIdle(timeout: 30)
        let user = manager._testMessages.first { $0.role == .user }
        let body = requestBodies().first ?? ""
        check("A2 the turn carries three files, their names and the oversize note; NO transcription request",
              user?.documentFileNames.count == 3 && user?.documentFileNames.allSatisfy { $0.hasSuffix(".m4a") } == true
                && transcription.bodies.isEmpty && body.contains("Nuova registrazione 3.m4a") && body.contains("not transcribed")
                && body.contains("could not be retrieved"), "docs \(user?.documentFileNames ?? []) transcriptions \(transcription.bodies.count)")
        // 20 MB boundary (20,971,520 downloads; one byte more does not;
        // a missing size is attempted).
        api.clear()
        for (id, size) in [("edge", 20_971_520), ("over", 20_971_521)] as [(String, Int)] {
            api.files[id] = Data([1, 2, 3])
            await manager._testProcessUpdate(Self.tgUpdate(200 + size % 7, audio(id, name: "\(id).m4a", size: size)))
        }
        api.files["nosize"] = Data([4, 5])
        await manager._testProcessUpdate(Self.tgUpdate(210, audio("nosize", name: "nosize.mp3", size: nil)))
        check("A3 20 MB boundary: exactly 20,971,520 is downloaded, 20,971,521 is refused, a missing size is attempted",
              api.requests.contains("download:edge") && !api.requests.contains("download:over") && api.requests.contains("download:nosize")
                && api.sent.count == 1 && api.sent[0].contains("over.m4a"), "\(api.requests)")
        // Video note → a file; reply context to an audio message.
        api.clear(); api.files["vn"] = Data(repeating: 7, count: 512)
        server.clear(); server.script([Self.chatText("seen")])
        await manager._testProcessUpdate(Self.tgUpdate(220, ["video_note": ["file_id": "vn", "file_unique_id": "uvn", "length": 240, "duration": 9],
                                                             "caption": "my round video"]))
        _ = await manager._testAwaitIdle(timeout: 30)
        let vnTurn = manager._testMessages.last { $0.role == .user }
        check("A4 video note: downloaded as an .mp4 file, caption starts the turn, no transcription",
              vnTurn?.content.contains("my round video") == true && vnTurn?.documentFileNames.contains { $0.hasSuffix(".mp4") } == true
                && transcription.bodies.isEmpty)
        api.clear(); api.files["ra"] = Data([9, 9, 9])
        server.clear(); server.script([Self.chatText("ok")])
        await manager._testProcessUpdate(Self.tgUpdate(221, ["text": "what is this?", "reply_to_message": [
            "message_id": 5, "date": 0, "chat": ["id": Self.tgChatId, "type": "private"],
            "audio": ["file_id": "ra", "file_unique_id": "ura", "duration": 125, "file_name": "memo.m4a"]]]))
        _ = await manager._testAwaitIdle(timeout: 30)
        let replyTurn = manager._testMessages.last { $0.role == .user }
        check("A5 reply to an audio message: '[Audio: name, m:ss]' context and the referenced file attached",
              replyTurn?.content.contains("[Audio: memo.m4a, 2:05]") == true && replyTurn?.referencedDocumentFileNames.count == 1)
        TelegramBotService.transportOverrideForTesting = nil
        OpenAITranscriptionService.overrideForTesting = nil
    }

    /// A malformed audio/video-note field always has a visible outcome.
    func tgMalformedSection() async throws {
        let api = TGFakeBotAPI(), transcription = TGFakeTranscription()
        let bad: [String: Any] = ["audio": ["file_id": 1, "duration": "?"]]
        // No caption → visible notice, nothing silent.
        var manager = await tgManager(api: api, transcription: transcription)
        await manager._testProcessUpdate(Self.tgUpdate(300, bad))
        check("M1 malformed audio, no caption: one visible notice, an agent note buffered",
              api.sent.count == 1 && api.sent[0].contains("couldn't read the audio file")
                && manager._testPendingAttachmentNotes.contains { $0.contains("audio file") }, "\(api.sent)")
        // Caption only → the turn runs with the caption and the note.
        manager = await tgManager(api: api, transcription: transcription)
        api.clear(); server.clear(); server.script([Self.chatText("ok")])
        await manager._testProcessUpdate(Self.tgUpdate(301, bad.merging(["caption": "here is the recording"]) { a, _ in a }))
        _ = await manager._testAwaitIdle(timeout: 30)
        let turn = manager._testMessages.last { $0.role == .user }
        check("M2 malformed audio with a caption: the turn carries the caption and the unavailable note; the notice is visible",
              turn?.content.contains("here is the recording") == true && turn?.content.contains("could not be retrieved") == true
                && api.sent.filter { $0.contains("couldn't read the audio file") }.count == 1, "\(api.sent)")
        // Malformed video note with reply context.
        manager = await tgManager(api: api, transcription: transcription)
        api.clear()
        await manager._testProcessUpdate(Self.tgUpdate(302, ["video_note": ["length": "x"], "reply_to_message": [
            "message_id": 3, "date": 0, "chat": ["id": Self.tgChatId, "type": "private"], "text": "earlier"]]))
        check("M3 malformed video note with reply context: visible notice", api.sent.count == 1 && api.sent[0].contains("video note"))
        // An unrelated earlier buffered file does not hide this update's notice.
        manager = await tgManager(api: api, transcription: transcription)
        api.clear(); api.files["doc"] = Data([1])
        await manager._testProcessUpdate(Self.tgUpdate(303, ["document": ["file_id": "doc", "file_unique_id": "ud", "file_name": "a.pdf", "file_size": 1]]))
        await manager._testProcessUpdate(Self.tgUpdate(304, bad))
        check("M4 an earlier buffered document does not suppress this update's notice", api.sent.count == 1 && api.sent[0].contains("audio"))
        TelegramBotService.transportOverrideForTesting = nil
        OpenAITranscriptionService.overrideForTesting = nil
    }

    func tgSafetyNetSection() async throws {
        let api = TGFakeBotAPI(), transcription = TGFakeTranscription()
        let manager = await tgManager(api: api, transcription: transcription)
        func replies() -> [String] { api.sent.filter { $0.hasPrefix("⚠️ I can't read") } }
        await manager._testProcessUpdate(Self.tgUpdate(400, ["sticker": ["file_id": "s", "file_unique_id": "us", "type": "regular", "width": 1, "height": 1]]))
        check("N1 sticker → one visible reply", replies() == ["⚠️ I can't read sticker messages yet. Send it as a file, a photo or text."], "\(api.sent)")
        api.clear()
        await manager._testProcessUpdate(Self.tgUpdate(401, ["poll": ["id": "p", "question": "q"]]))
        await manager._testProcessUpdate(Self.tgUpdate(402, ["live_photo": ["file_id": "l"]]))
        check("N2 poll and live photo → one reply each", replies().count == 2 && replies()[1].contains("live photo"))
        api.clear()
        for (i, kind) in ["pinned_message", "giveaway_created", "giveaway_completed", "checklist_tasks_done", "checklist_tasks_added"].enumerated() {
            await manager._testProcessUpdate(Self.tgUpdate(410 + i, [kind: ["x": 1]]))
        }
        check("N3 service events → no reply", replies().isEmpty)
        await manager._testProcessUpdate(Self.tgUpdate(420, ["sticker": ["file_id": "s"]], chat: 999, from: 999))
        check("N4 a non-paired chat → nothing at all", api.sent.isEmpty)
        let redelivered = Self.tgUpdate(430, ["sticker": ["file_id": "s"]])
        await manager._testProcessUpdate(redelivered)
        await manager._testProcessUpdate(redelivered)
        check("N5 the same update delivered twice → one reply", replies().count == 1)
        api.clear()
        for i in 0..<3 {
            await manager._testProcessUpdate(Self.tgUpdate(440 + i, ["live_photo": ["file_id": "l\(i)"], "media_group_id": "album-1"]))
        }
        check("N6 an album of three → one reply", replies().count == 1)
        // Per-update outcome: an earlier buffered file (a different update)
        // does not count as this sticker's content.
        api.clear(); api.files["pre"] = Data([1])
        await manager._testProcessUpdate(Self.tgUpdate(445, ["document": ["file_id": "pre", "file_unique_id": "up", "file_name": "a.txt", "file_size": 1]]))
        await manager._testProcessUpdate(Self.tgUpdate(446, ["sticker": ["file_id": "s2"]]))
        check("N11 a sticker after an unrelated buffered document still gets its reply", replies().count == 1, "\(api.sent)")
        // A voice note is never touched by the safety net or its dedup.
        api.clear(); api.files["vv"] = Data(repeating: 3, count: 256)
        server.clear(); server.script([Self.chatText("ok")])
        await manager._testProcessUpdate(Self.tgUpdate(450, ["voice": ["file_id": "vv", "file_unique_id": "uvv", "duration": 2]]))
        _ = await manager._testAwaitIdle(timeout: 30)
        check("N7 a voice note right after is processed normally (transcribed, no reply)",
              transcription.bodies.count == 1 && replies().isEmpty && manager._testMessages.last { $0.role == .user }?.content == transcription.text)
        // Bounded dedup: after more than 512 newer keys the oldest is gone.
        api.clear()
        for i in 0..<200 { await manager._testProcessUpdate(Self.tgUpdate(1000 + i, ["dice": ["emoji": "🎲", "value": 3]])) }
        check("N8 200 distinct dice → 200 replies", replies().count == 200)
        await manager._testProcessUpdate(redelivered)
        check("N9 within the bound, the old redelivery is still deduplicated", replies().count == 200)
        for i in 0..<200 { await manager._testProcessUpdate(Self.tgUpdate(2000 + i, ["dice": ["emoji": "🎲", "value": 3]])) }
        api.clear()
        await manager._testProcessUpdate(redelivered)
        check("N10 past the bound (512 keys), the oldest entry is evicted", replies().count == 1)
        TelegramBotService.transportOverrideForTesting = nil
        OpenAITranscriptionService.overrideForTesting = nil
    }
}
